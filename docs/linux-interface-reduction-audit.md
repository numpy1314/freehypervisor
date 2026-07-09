# Linux 接口缩减审查记录

## 结论

本轮审查后，能确定缩减的接口是 Linux 侧 `host_fdt_paddr` 胶水链：

- 删除 `axvisor_linux_arch_host_fdt_paddr`
- 删除 `axvisor_adapter_host_fdt_paddr`
- 删除 `host_fdt_paddr` module parameter
- Linux bridge 的 `ArchIf::host_fdt_paddr()` 固定返回 `None`
- Linux host FDT 输入只保留 `host_fdt_vaddr/host_fdt_size`，也就是
  `ArchIf::host_fdt_bytes()`

保留公共 `ArchIf::host_fdt_paddr()` trait 方法。这个方法仍是非 Linux host 或
bootloader 直接传入 DTB 物理地址路径的有效语义，不能因为 Linux loadable module
路径已经改成 bytes provider 就从公共接口删除。

验证结果：

```text
bash tools/build-riscv-linux-host-module.sh
```

通过。

```text
RUN_DIR=/tmp/axvisor-riscv64-linux-guest-smoke.fdt-paddr-reduction \
HOST_ROOTFS_IMG=/tmp/axvisor-riscv64-host-rootfs.fdt-paddr-reduction.img \
SMOKE_GUEST_ROOTFS_IMG=/tmp/axvisor-qemu-riscv64-linux-guest-rootfs.fdt-paddr-reduction.img \
TIMEOUT_SECS=180 \
bash tools/verify-riscv-linux-host-linux-smoke.sh
```

通过，结果文件包含 `AXVISOR_SMOKE_PASS=1`。

修改前快照：

```text
/tmp/axvisor-interface-reduction-fdt-baseline-20260627-125450/relevant-sources.tgz
```

## 已确认可缩减

### 1. 连续内存分配/释放

状态：已完成。

这对接口不能通过“循环 `alloc_frame()` 并返回第一页 HPA”实现，因为原语义要求
调用者能按 `base + offset` 访问真实连续 HPA。正确缩减方式是删除 Linux 侧
连续物理内存能力要求，把需要普通多页内存的路径改成逐页分配和逐页映射。

记录见：

- `docs/linux-contiguous-memory-interface-reduction.md`

### 2. Linux `host_fdt_paddr` 胶水

状态：已完成。

Linux loadable module 无法可靠取得 boot FDT 的物理地址。当前可用语义是：

- 用户通过 `host_fdt_path` 提供 DTB blob。
- C shim 读入虚拟连续 buffer。
- Rust bridge 通过 `host_fdt_vaddr/host_fdt_size` 组合成 `&'static [u8]`。
- core 优先使用 `host_fdt_bytes()`。

因此 Linux 侧不需要再暴露 `host_fdt_paddr`，这个 paddr fallback 已从 Linux
adapter/bridge/shim 中移除。

## 已确认不能组合替代

### `SyncIf::wait_queue_wait` 和 `wait_queue_wait_until`

不能合并。

`wait_queue_wait(queue)` 的语义是无条件睡眠，直到被 wake 或 queue destroyed。
`wait_queue_wait_until(queue, condition)` 的语义是条件已经满足时立即返回，否则
睡眠并在每次 wake 后重新检查条件。

用常量闭包组合会改变语义：

- `condition = || true` 会立即返回，不会睡眠。
- `condition = || false` 会被 wake 后继续睡，无法表达“被唤醒一次就返回”。

### `SyncIf::wait_queue_wake_all` 和 `wait_queue_wake_one`

不能合并。

`wake_all` 需要原子地把 `woken_ticket` 推进到 `next_ticket` 并通知所有 waiter。
用循环 `wake_one` 需要可靠 waiter 数，当前接口没有提供 waiter 数；循环期间还会
引入新 waiter 竞争，语义不等价。

### `HostIf::emerg_write_bytes` 和 `ConsoleIf::write_bytes`

不能合并。

Linux 实现中的 `emerg_write_bytes` 走 `pr_emerg`，按行缓冲并过滤高频调试输出，
且被 panic/alloc-error 路径使用。`ConsoleIf::write_bytes` 是普通 console 输出，
没有紧急日志级别和 panic 路径语义。

### `MemoryIf::virt_to_phys`

不能删除。

它不是 `phys_to_virt` 的反函数缓存，也不能从 `alloc_frame` 推导。当前 Linux 侧
仍需要把 runtime buffer、guest image load buffer、`HostPage` HVA 反查成 HPA。

### `TaskIf::current_task`

不能由 `spawn_task_raw` 或 `join_task` 组合。

当前调用点包括 vCPU 初始化和 AxVisor context 读取，需要“当前执行上下文对应的
task handle”。spawn/join 只能创建或等待指定 task，不能查询当前 task。

### `TaskIf::join_task`

不能删除。

VM/vCPU teardown 需要等待已创建 task 退出并回收 Linux task 资源。这个同步语义不
能由 `yield_now` 或 `current_task` 组合出来。

### `TimeIf::current_time_nanos` 和 `set_oneshot_timer`

不能合并。

前者是读时钟，后者是向 Linux hrtimer backend 编程一次性 deadline。读时间不能
产生 timer interrupt，设置 timer 也不能替代当前时间读取。

### `IrqIf::register_irq_handler` 和 `handle_irq`

不能合并。

`register_irq_handler` 建立 vector 到 handler 的绑定，`handle_irq` 是中断到达时
调度已注册 handler。注册态和触发态是两个不同生命周期。

### `HostIf::release_host_filesystems`

不能删除。

这个 hook 当前承担 guest passthrough 前释放 host MMIO 设备所有权的工作。它不是
文件系统 flush，也不能由普通 FS 接口组合。

### FS 接口组

公共 trait 层不能进一步合并。

- `create_file(path)` 在 Linux bridge 内部已经复用带 flags 的
  `axvisor_linux_fs_open_file(...)`，但公共 `open_file(path)` 没有 flags/mode，
  所以在公共 trait 层不能由 `open_file` 表达创建语义。
- `path_metadata(path)` 不能安全替换为 `open_file + file_metadata + close_file`。
  目录、特殊文件、权限和 symlink follow 语义都会变化。
- `file_flush(file)` 对写路径提供 fsync 语义，不能由 `file_write` 自动推出。
- `fs_current_dir` 和 `fs_set_current_dir` 是进程级路径状态语义，不能由
  `open/read_dir` 组合。

### `VmmIf`

不计入 Linux host 胶水缩减范围。

`VmmIf` 由 `axvisor_core` 实现，不由 Linux host adapter 实现。它是 core 暴露给
底层 vCPU、虚拟设备和架构代码的内部 VMM 服务接口。`inject_interrupt_to_cpus`
当前确实在 core 实现中循环调用 `inject_interrupt`，但这是 core 内部 helper
组合，不减少 Linux 侧需要实现的 host 接口。

## 下一步候选

当前没有第二个可以直接删除且保持语义等价的 Linux 必选接口。后续若要继续缩减，
需要改变公共 trait 形状，而不是只删 Linux glue：

- 把 FS 的 `open_file/create_file` 改为一个带 flags/mode 的 `open_file_ext`。
- 把 `ArchIf::host_fdt_paddr` 从公共必选接口降为可选 provider，只保留
  `host_fdt_bytes` 作为 core 读取入口。
- 把 wait queue 抽象改成更高层的 `WaitQueue` 对象方法，由 API 层自行组合
  `wait/wait_until/wake_one/wake_all`，但底层 host 仍必须提供等价原语。
