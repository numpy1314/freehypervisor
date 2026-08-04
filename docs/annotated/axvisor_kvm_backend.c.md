# `axvisor_kvm_backend.c` 逐函数精讲

## 文件总览

### 角色

本文件是 `axvisor_kvm.ko` 的**后端抽象层（backend dispatch layer）**。`/dev/kvm` ABI provider（对上层 VMM，如 Firecracker/gVisor，模拟 KVM 接口的那一侧）通过本层把每一个"执行面"操作（创建 VM/vCPU、映射内存、运行 vCPU、注入中断等）分派给一个当前注册的**后端实现**（`axvisor_kvm_backend_ops`）。

关键设计动机写在文件头注释（第 2-8 行）：ABI provider 可能在**真正的 AxVisor 后端尚未可用**时就被加载。在这种"无后端"状态下，每个执行面操作都返回 `-EOPNOTSUPP`，而 `KVM_RUN` 会向用户态报告一个确定性的 fail-entry（见 `run_vcpu`，第 262-284 行），而不是崩溃或未定义行为。

### 在分派体系里的位置

- **上游（调用者）**：`/dev/kvm` 字符设备的 ioctl 处理层（`main.c` 一侧）调用本文件导出的 `axvisor_kvm_backend_*` 函数。
- **本层**：持锁读取当前注册的 `ops` 表，做空指针/空函数指针检查，然后把调用转发给 `ops->xxx`。
- **下游（后端）**：具体后端（如 `axvisor_kvm_axvisor_backend.c` 里的 `axvisor_backend_ops`）通过 `axvisor_kvm_backend_register()` 注册自己的 ops 表。

### 暴露/依赖的符号

- **依赖**：`struct axvisor_kvm_backend_ops`、`struct axkvm_backend_vm_state`、`struct axkvm_backend_vcpu_state`、`struct axkvm_backend_exit`、`AXKVM_BACKEND_EXIT_FAIL_ENTRY`（均来自 `axvisor_kvm_backend.h`，第 17 行 include）；`struct kvm_regs`（Linux UAPI）。
- **内部状态**：`axvisor_kvm_backend_lock`（mutex，第 19 行）、`axvisor_kvm_backend_ops`（当前注册的 ops 指针，第 20 行）。
- **导出（`EXPORT_SYMBOL_GPL`）**：`axvisor_kvm_backend_register` / `_unregister` 以及全部 15 个执行面转发函数。
- **`__weak` 桩**：`axvisor_kvm_builtin_backend_init` / `_exit`（第 342-349 行），允许内建后端文件用强符号覆盖。

---

## 逐函数讲解

### 模块序言与静态状态（第 10-20 行）

- 第 10 行 `#define pr_fmt` 给本文件所有 `pr_*` 日志加统一前缀 `axvisor_kvm_backend: `。
- 第 19 行 `DEFINE_MUTEX(axvisor_kvm_backend_lock)` 定义保护 ops 指针的互斥锁。
- 第 20 行 `axvisor_kvm_backend_ops` 是唯一的全局注册槽——本层只支持**单一后端**同时注册（见 register 的 `-EBUSY`）。

### `axvisor_kvm_backend_get`（第 22-33 行）

获取当前 ops 表并**提升其模块引用计数**，防止使用期间后端模块被卸载。

- 第 26 行持锁，第 27 行读出 `ops`。
- 第 28-29 行是关键的并发安全点：若 ops 声明了 `owner`（所属模块），调用 `try_module_get(ops->owner)`；若拿引用失败（模块正在卸载），把 `ops` 置 NULL，让调用方走 `-EOPNOTSUPP` 分支。
- 第 30 行解锁，第 32 行返回。锁只保护"读指针 + 拿引用"这段临界区，实际的后端调用在锁外进行（避免长时间持锁）。

### `axvisor_kvm_backend_put`（第 35-39 行）

与 `_get` 配对，释放模块引用。第 37-38 行：仅当 `ops` 非空且有 `owner` 时才 `module_put`。注意传入 NULL 也安全（对应 get 失败的情形）。

### `axvisor_kvm_backend_register`（第 41-57 行）

后端注册入口，导出符号。

- 第 45-46 行拒绝 NULL ops（`-EINVAL`）。
- 第 48-53 行持锁：若已有后端占用槽位，返回 `-EBUSY`（单后端语义）；否则把 `ops` 写入全局槽。
- 第 57 行 `EXPORT_SYMBOL_GPL` 让内建后端和外部模块都能调用。

### `axvisor_kvm_backend_unregister`（第 59-66 行）

注销入口。第 62-63 行持锁，仅当当前槽位恰好等于传入的 `ops` 时才清空（防止误注销他人的表）。

### 执行面转发函数——统一模板

第 68-340 行的 15 个函数共享同一套"get / 检查 / 分派 / put"骨架。它们是本层与后端 ops 表之间的**函数指针分派边界**，逐个说明其差异点。

### `axvisor_kvm_backend_create_vm`（第 68-87 行）

- 第 73-74 行**先把出参 `*backend_vm` 清零**，保证即使后端不可用，调用方拿到的也是确定值 0。
- 第 76 行 `_get`；第 77-80 行做双重检查：`ops` 为空 **或** `ops->create_vm` 函数指针为空，都返回 `-EOPNOTSUPP` 并跳到 `out`。
- 第 82 行分派到 `ops->create_vm(backend_vm)`。
- 第 83-85 行 `out:` 标签统一 `_put` 后返回——保证任何路径都释放模块引用。这个 goto-out 结构是后续所有转发函数的范式。

### `axvisor_kvm_backend_destroy_vm`（第 89-98 行）

返回 `void` 的销毁路径。第 94 行用 `if (ops && ops->destroy_vm)` 直接内联判断（无需返回错误码），有实现就调用，无实现就静默跳过；第 96 行始终 `_put`。传 NULL ops 给 `_put` 安全。

### `axvisor_kvm_backend_set_vm_state`（第 100-117 行）

把 VM 级状态（`struct axkvm_backend_vm_state`，含 irqchip/PIT/TSS/identity-map 等）转发给后端。标准 get/检查/分派/put 模板，无特殊处理。

### `axvisor_kvm_backend_map_page`（第 119-135 行）

映射单页 `gpa -> hpa`（带 `flags`）。标准模板转发到 `ops->map_page`。

### `axvisor_kvm_backend_map_page_nolog`（第 137-154 行）

与 `map_page` 语义相同，但转发到独立的 `ops->map_page_nolog`。"nolog"变体供热路径批量映射时避免每页日志刷屏——分派目标不同，是两条独立函数指针。

### `axvisor_kvm_backend_unmap_range`（第 156-172 行）

按 `(gpa, size)` 范围解除映射。标准模板转发到 `ops->unmap_range`。

### `axvisor_kvm_backend_create_vcpu`（第 174-194 行）

创建 vCPU。与 `create_vm` 同样在第 180-181 行**先清零出参 `*backend_vcpu`**，再走标准模板转发 `(backend_vm, vcpu_id, backend_vcpu)`。

### `axvisor_kvm_backend_destroy_vcpu`（第 196-205 行）

`void` 销毁路径，结构同 `destroy_vm`（第 201 行 `if (ops && ops->destroy_vcpu)`）。

### `axvisor_kvm_backend_set_vcpu_state`（第 207-224 行）

转发 vCPU 完整初始状态（`struct axkvm_backend_vcpu_state`）到 `ops->set_vcpu_state`。标准模板。

### `axvisor_kvm_backend_get_vcpu_regs`（第 226-242 行）

读回 vCPU 通用寄存器到 `struct kvm_regs *regs`（Linux UAPI 结构）。标准模板转发到 `ops->get_vcpu_regs`。这是少数**读回**方向的转发。

### `axvisor_kvm_backend_boot_vm`（第 244-260 行）

引导整台 VM（AxVM 的 boot 语义）。标准模板转发到 `ops->boot_vm`。

### `axvisor_kvm_backend_run_vcpu`（第 262-284 行）——fail-entry 语义的核心

本层最关键的确定性行为所在。

- 第 268-271 行：**在分派前就把出参 `exit` 预填为 fail-entry**——`exit->reason = AXKVM_BACKEND_EXIT_FAIL_ENTRY`，`hardware_entry_failure_reason = 0`。这实现了文件头注释承诺的"无后端时 `KVM_RUN` 报告确定性 fail-entry"：即便后端不存在，上层 VMM 收到的也是一个格式良好的 KVM_EXIT_FAIL_ENTRY，而非垃圾数据。
- 第 273-277 行标准 get/检查，无后端时返回 `-EOPNOTSUPP`（此时 `exit` 已被预填）。
- 第 279 行分派到 `ops->run_vcpu(backend_vcpu, exit)`，由后端覆写 `exit` 的真实退出原因。
- 第 280-282 行统一 `_put` 返回。

### `axvisor_kvm_backend_complete_mmio_read`（第 286-303 行）

MMIO 读补全：上层 VMM 处理完 MMIO 读后，把数据 `(data, len)` 回填给 vCPU 以便恢复执行。标准模板转发到 `ops->complete_mmio_read`。

### `axvisor_kvm_backend_complete_io_read`（第 305-322 行）

Port I/O 读补全，与 MMIO 变体对称，转发到 `ops->complete_io_read`。

### `axvisor_kvm_backend_inject_irq`（第 324-340 行）

按 GSI 号向 VM 注入中断。标准模板转发到 `ops->inject_irq(backend_vm, gsi)`。

### `axvisor_kvm_builtin_backend_init` / `_exit`（第 342-349 行）——`__weak` 桩

- 第 342-345 行 `__weak int axvisor_kvm_builtin_backend_init(void)` 默认返回 0（无内建后端时的空实现）。
- 第 347-349 行 `__weak void axvisor_kvm_builtin_backend_exit(void)` 默认空操作。

`__weak` 的意义：当 `axvisor_kvm_axvisor_backend.c` 被一起链接进 `.ko` 时，它提供的**强符号**同名函数会覆盖这两个弱桩，从而在模块初始化时真正注册内建 AxVisor 后端。这是 C 层内建后端"可选接入"的链接期开关。

### 模块尾（第 351 行）

`MODULE_LICENSE("GPL")` 声明许可证。

---

## 小结

本文件仅约 351 行，却是整个 KVM ABI provider 的分派枢纽。它用一个受 mutex 保护的单例 ops 指针 + `try_module_get`/`module_put` 引用计数，把 15 个执行面操作安全地转发给可插拔后端；核心确定性保证是 `run_vcpu` 的 fail-entry 预填与全线 `-EOPNOTSUPP` 降级。
