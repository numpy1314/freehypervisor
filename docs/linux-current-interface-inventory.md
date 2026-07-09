# Linux 当前接口清单

本文档记录当前 no-FsIf 方案完成后的源码快照。统计口径是 RISC-V
Linux host smoke 构建：

- `linux-host-kernel/drivers/virt/axvisor/Makefile` 对 `axvisor_api`、
  `axvisor_core` 和 `axvisor_linux_bridge` 启用 `feature="shell"`。
- 当前 Linux smoke 构建不再启用 `feature="fs"`。
- 目标架构是 `riscv64`，因此只统计 RISC-V 可编译到的 `ArchIf` 方法。
- `VmmIf` 是 AxVisor core 内部服务接口，由 `axvisor_core` 实现，不属于
  Linux host adapter 需要实现的胶水。

## 1. 公开 `axvisor_api` trait

当前 RISC-V Linux smoke 构建下，公开 trait 方法总数是 32 个。

### 1.1 Linux host adapter 需要实现的 host glue：26 个

`HostIf`：5 个。

- `get_host_cpu_num`
- `init_percpu`
- `release_host_filesystems`
- `exit`
- `emerg_write_bytes`

`release_host_filesystems` 的历史命名保留，但当前语义是释放 host-owned
passthrough 资源，不是 `FsIf` 文件系统接口。

`ConsoleIf`：2 个。

- `write_bytes`
- `read_bytes`

`TimeIf`：2 个。

- `current_time_nanos`
- `set_oneshot_timer`

`SyncIf`：6 个。

- `create_wait_queue`
- `destroy_wait_queue`
- `wait_queue_wait`
- `wait_queue_wait_until`
- `wait_queue_wake_one`
- `wait_queue_wake_all`

`TaskIf`：4 个。

- `spawn_task_raw`
- `join_task`
- `current_task`
- `yield_now`

`IrqIf`：2 个。

- `handle_irq`
- `register_irq_handler`

`MemoryIf`：4 个。

- `alloc_frame`
- `dealloc_frame`
- `phys_to_virt`
- `virt_to_phys`

`ArchIf`，RISC-V Linux host 生效部分：1 个。

- `host_fdt_bytes`

Linux 侧实际提供的是 `host_fdt_bytes()` 所需的
`host_fdt_vaddr/host_fdt_size` 胶水。`host_fdt_paddr()` 仍保留给非 Linux
DTB host，但不再属于 Linux RISC-V host 必须实现的接口。

### 1.2 不属于 Linux host glue 的公开接口：6 个

`VmmIf`：6 个。

- `vcpu_num`
- `active_vcpus`
- `inject_interrupt`
- `inject_interrupt_to_cpus`
- `register_timer`
- `cancel_timer`

这 6 个接口由 `axvisor_core` 提供给架构、vCPU、设备和 timer 代码使用，不由
Linux host adapter 实现。

### 1.3 当前 RISC-V 构建不生效的接口

`FsIf` 在 `axvisor_api/src/fs.rs` 中仍作为 upstream 可选 API 存在，但它受
`#[cfg(feature = "fs")]` 控制。当前 Linux smoke 构建不启用 `feature="fs"`，
Linux bridge 不实现 `FsIf`，Linux adapter/shim 不导出 `axvisor_linux_fs_*`
或 `axvisor_adapter_fs_*`。

这些 `ArchIf` 方法存在于公共源码中，但不计入 RISC-V Linux smoke 的 32 个方法：

- `host_fdt_paddr`：非 Linux DTB host 路径；Linux RISC-V host 只走
  `host_fdt_bytes`。
- `host_tsc_frequency_mhz`：`x86_64` 专用。
- `hardware_inject_virtual_interrupt`：`aarch64` 专用。
- `read_vgicd_typer`：`aarch64` 专用。
- `read_vgicd_iidr`：`aarch64` 专用。
- `get_host_gicd_base`：`aarch64` 专用。
- `get_host_gicr_base`：`aarch64` 专用。
- `fetch_irq`：`aarch64` 专用。

## 2. Linux Rust bridge 向下依赖的 FFI

`axvisor_linux_bridge/src/lib.rs` 通过 `unsafe extern "C"` 调用 Linux adapter
导出的函数。当前列表没有 FS 符号。

Host/console/time：10 个。

- `axvisor_linux_host_get_cpu_num`
- `axvisor_linux_host_current_cpu_id`
- `axvisor_linux_host_init_percpu`
- `axvisor_linux_host_release_host_filesystems`
- `axvisor_linux_host_exit`
- `axvisor_linux_console_write_bytes`
- `axvisor_linux_console_read_bytes`
- `axvisor_linux_host_emerg_write_bytes`
- `axvisor_linux_time_current_time_nanos`
- `axvisor_linux_time_set_oneshot_timer`

Sync/task/irq：12 个。

- `axvisor_linux_sync_create_wait_queue`
- `axvisor_linux_sync_destroy_wait_queue`
- `axvisor_linux_sync_wait_queue_wait`
- `axvisor_linux_sync_wait_queue_wait_until`
- `axvisor_linux_sync_wait_queue_wake_one`
- `axvisor_linux_sync_wait_queue_wake_all`
- `axvisor_linux_task_spawn_raw`
- `axvisor_linux_task_join`
- `axvisor_linux_task_current`
- `axvisor_linux_task_yield_now`
- `axvisor_linux_irq_handle`
- `axvisor_linux_irq_register`

Memory/passthrough/arch：11 个。

- `axvisor_linux_memory_alloc_frame`
- `axvisor_linux_memory_dealloc_frame`
- `axvisor_linux_memory_phys_to_virt`
- `axvisor_linux_memory_virt_to_phys`
- `axvisor_linux_memory_register_guest_ram`
- `axvisor_linux_memory_mmio_read32`
- `axvisor_linux_memory_mmio_write32`
- `axvisor_linux_riscv_plic_complete_passthrough_irq`
- `axvisor_linux_host_register_passthrough_device`
- `axvisor_linux_arch_host_fdt_vaddr`
- `axvisor_linux_arch_host_fdt_size`

Runtime allocator：3 个。

- `axvisor_adapter_runtime_alloc`
- `axvisor_adapter_runtime_realloc`
- `axvisor_adapter_runtime_dealloc`

合计：36 个向下 FFI 符号。其中 `register_guest_ram`、MMIO、PLIC complete 和
passthrough device registration 是 Linux/RISC-V passthrough 扩展，不是公开
`axvisor_api::MemoryIf` 方法。

## 3. Linux Rust bridge 向 core/adapter 暴露的符号

`axvisor_linux_bridge/src/lib.rs` 当前导出 11 个 `axvisor_linux_bridge_*`
符号。

Rust ABI：5 个。

- `axvisor_linux_bridge_mmio_read32`
- `axvisor_linux_bridge_mmio_write32`
- `axvisor_linux_bridge_complete_passthrough_irq`
- `axvisor_linux_bridge_register_guest_ram`
- `axvisor_linux_bridge_register_passthrough_device`

C ABI：6 个。

- `axvisor_linux_bridge_handle_irq`
- `axvisor_linux_bridge_boot_run`
- `axvisor_linux_bridge_timer_check_events`
- `axvisor_linux_bridge_inject_current_interrupt`
- `axvisor_linux_bridge_inject_interrupt`
- `axvisor_linux_bridge_current_vm_id`

## 4. Linux Rust adapter 导出的 C ABI

`axvisor_adapter_main.rs` 当前导出 47 个 `axvisor_linux_*` C ABI 符号，不包含
FS 符号。

Host/console/guest-console：14 个。

- `axvisor_linux_host_get_cpu_num`
- `axvisor_linux_host_current_cpu_id`
- `axvisor_linux_host_init_percpu`
- `axvisor_linux_host_release_host_filesystems`
- `axvisor_linux_host_exit`
- `axvisor_linux_console_write_bytes`
- `axvisor_linux_console_read_bytes`
- `axvisor_linux_console_shell_ready`
- `axvisor_linux_console_enqueue_bytes`
- `axvisor_linux_guest_console_write_bytes`
- `axvisor_linux_guest_console_read_bytes`
- `axvisor_linux_guest_console_enqueue_bytes`
- `axvisor_linux_guest_console_drain_bytes`
- `axvisor_linux_host_emerg_write_bytes`

Time/sync/task/irq：14 个。

- `axvisor_linux_time_current_time_nanos`
- `axvisor_linux_time_set_oneshot_timer`
- `axvisor_linux_sync_create_wait_queue`
- `axvisor_linux_sync_destroy_wait_queue`
- `axvisor_linux_sync_wait_queue_wait`
- `axvisor_linux_sync_wait_queue_wait_until`
- `axvisor_linux_sync_wait_queue_wake_one`
- `axvisor_linux_sync_wait_queue_wake_all`
- `axvisor_linux_task_spawn_raw`
- `axvisor_linux_task_join`
- `axvisor_linux_task_current`
- `axvisor_linux_task_yield_now`
- `axvisor_linux_irq_handle`
- `axvisor_linux_irq_register`

Memory/passthrough/arch：19 个。

- `axvisor_linux_memory_alloc_frame`
- `axvisor_linux_memory_dealloc_frame`
- `axvisor_linux_memory_phys_to_virt`
- `axvisor_linux_memory_virt_to_phys`
- `axvisor_linux_memory_register_guest_ram`
- `axvisor_linux_memory_mmio_read32`
- `axvisor_linux_memory_mmio_write32`
- `axvisor_linux_riscv_plic_complete_passthrough_irq`
- `axvisor_linux_host_register_passthrough_device`
- `axvisor_linux_passthrough_device_count`
- `axvisor_linux_passthrough_device_base_hpa`
- `axvisor_linux_passthrough_device_length`
- `axvisor_linux_passthrough_device_irq_id`
- `axvisor_linux_passthrough_device_vm_id`
- `axvisor_linux_passthrough_irq_vm_id`
- `axvisor_linux_passthrough_irq_registered`
- `axvisor_linux_passthrough_irq_inject`
- `axvisor_linux_arch_host_fdt_vaddr`
- `axvisor_linux_arch_host_fdt_size`

## 5. Linux C shim backing 函数

`axvisor_adapter_shim.c` 当前提供 host FDT、passthrough resource handoff、task、
console、guest console、time、memory、MMIO、PLIC complete、runtime allocator
等 backing 函数，不再提供 `axvisor_adapter_fs_*` backing 函数。

## 6. 镜像和配置来源

当前 Linux Kbuild 路径通过 `tools/gen-axvisor-linux-vm-configs-static.py` 生成固定
路径：

- `linux-host-kernel/drivers/virt/axvisor/vendor/upstream/axvisor_core/src/vm_configs_static.rs`

生成内容满足：

- VM TOML 中 `image_location = "memory"`。
- guest kernel/dtb 通过绝对路径 `include_bytes!()` 编入模块。
- `init_guest_vms()` 在 no-FsIf 构建下先得到空的 `filesystem_vm_configs()`，
  再 fallback 到 `static_vm_configs()`。

因此 Linux host rootfs 不再需要 `/guest/vm_default/*.toml`、`/guest/qemu-riscv64`
或 `/guest/linux-riscv64-qemu-smp1.dtb`。guest rootfs 仍作为 passthrough
virtio-blk 磁盘镜像放在 `/guest/rootfs.img`。

## 7. 当前结论

当前 RISC-V Linux host adapter 的公开 host glue 需求是 26 个
`axvisor_api` trait 方法。旧清单中的 42 个来自启用 `feature="fs"` 后额外包含的
15 个 `FsIf` 方法；当前 no-FsIf 路径已经去掉这 15 个 Linux FS glue。随后
`host_fdt_paddr` 也从 Linux RISC-V host 必须实现接口中移除，Linux 侧只保留
`host_fdt_bytes`。

源码检查命令：

```sh
rg 'feature="fs"|axvisor_linux_fs_|axvisor_adapter_fs_|FsIf' linux-host-kernel/drivers/virt/axvisor -S
```

当前允许出现的唯一命中是 upstream 可选 trait 定义：

- `linux-host-kernel/drivers/virt/axvisor/vendor/upstream/axvisor_api/src/fs.rs:pub trait FsIf`

Linux 适配路径中的 `Makefile`、`axvisor_linux_bridge/src/lib.rs`、
`axvisor_adapter_main.rs`、`axvisor_adapter_shim.c` 不应再命中 FS glue。
