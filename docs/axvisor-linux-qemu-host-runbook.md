# AxVisor Linux Host QEMU Runbook

当前目标是先把 Linux host 跑起来，再在 guest 里 `insmod axvisor_adapter.ko` 观察运行时日志。

当前已定位的关键前提：

- 宿主 Linux 内核必须启用 `CONFIG_RUST=y`
- 否则 Rust-for-Linux 提供的 `kernel/core/helpers` 导出符号不会进入宿主内核
- 结果就是 `axvisor_adapter.ko` 在 `insmod` 时出现 `Unknown symbol rust_helper_*` 和 Rust mangled symbol

## 产物

- RISC-V host kernel `Image`
  - `linux-host-kernel/build-axvisor/arch/riscv/boot/Image`
- AxVisor Linux host module
  - `linux-host-kernel/build-axvisor/drivers/virt/axvisor/axvisor_adapter.ko`
- Ubuntu riscv64 rootfs tarball
  - `/tmp/ubuntu-riscv64-root.tar.xz`

## 1. 生成 rootfs tarball

如果本机还没有 `/tmp/ubuntu-riscv64-root.tar.xz`，先生成它：

```bash
cd /home/bullet1517/freehypervisor
bash tools/create-riscv64-root-tar.sh
```

这个脚本会用 `qemu-debootstrap` 生成一个最小 Ubuntu riscv64 rootfs，并打包成：

- `/tmp/ubuntu-riscv64-root.tar.xz`

注意：这个步骤需要 `sudo`，也需要宿主机能访问 Ubuntu ports 仓库。

## 2. 生成 host rootfs

```bash
cd /home/bullet1517/freehypervisor
bash tools/build-riscv-linux-host-rootfs.sh
```

这个脚本会：

- 解压 `/tmp/ubuntu-riscv64-root.tar.xz`
- 拷贝 `axvisor_adapter.ko` 到 guest 的 `/root/axvisor/`
- 写入 `/root/axvisor/load-axvisor.sh`
- 给 `ttyS0` 配 root 自动登录
- 生成 `/tmp/axvisor-riscv64-host-rootfs.img`

注意：这个脚本会使用 `sudo mount` 和 `sudo umount`。

在重新打包 rootfs 之前，先确认模块是按 in-tree 目标方式构建出来的，而不是用 `M=...` 空跑：

```bash
cd /home/bullet1517/freehypervisor/linux-host-kernel
env \
PATH=/nix/store/wfjvqf9zlh05w0admf7x1mz0jn4bfy21-llvm-21.1.8/bin:/nix/store/pjlw516aqj888w9j0z2249n8yzbnbn4x-lld-21.1.8/bin:/nix/store/wcwr4iq7c8f4ygn8bd1q0k3i51lmhz35-clang-21.1.8/bin:/nix/store/7av2pli48lhqvdwzvvxv7sdlgrmz04l4-rust-bindgen-0.72.1/bin:/home/bullet1517/.cargo/bin:/home/bullet1517/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin \
RUSTUP_TOOLCHAIN=nightly-2026-04-03 \
BINDGEN=/nix/store/7av2pli48lhqvdwzvvxv7sdlgrmz04l4-rust-bindgen-0.72.1/bin/bindgen \
LIBCLANG_PATH=/nix/store/jdgw7h0g0l8clmcasaspxnx6v62jz1il-clang-21.1.8-lib/lib \
RUST_LIB_SRC=/home/bullet1517/.rustup/toolchains/nightly-2026-04-03-x86_64-unknown-linux-gnu/lib/rustlib/src/rust/library \
CLANG=/nix/store/wcwr4iq7c8f4ygn8bd1q0k3i51lmhz35-clang-21.1.8/bin/clang \
make V=1 ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- LLVM=1 \
HOSTCC=gcc HOSTCXX=g++ HOSTLD=gcc \
O=/home/bullet1517/freehypervisor/linux-host-kernel/build-axvisor \
drivers/virt/axvisor/axvisor_adapter.ko -j1
```

产物应位于：

- `linux-host-kernel/build-axvisor/drivers/virt/axvisor/axvisor_adapter.ko`

## 3. 配置 host kernel

先把宿主内核配置切到带 Rust 支持的状态：

```bash
cd /home/bullet1517/freehypervisor
bash tools/configure-riscv-linux-host-kernel.sh
```

这个脚本会：

- 以 `defconfig` 初始化 `linux-host-kernel/build-axvisor/.config`
- 合并上游 `kernel/configs/rust.config`
- 追加 AxVisor host 当前最基本需要的本地配置片段
- 执行 `olddefconfig`

至少应看到这些配置为 `y`：

- `CONFIG_RUST`
- `CONFIG_MODULES`
- `CONFIG_VIRTIO_BLK`
- `CONFIG_EXT4_FS`

## 4. 启动 RISC-V Linux host

```bash
cd /home/bullet1517/freehypervisor
bash tools/run-riscv-linux-host-qemu.sh
```

默认参数：

- QEMU:
  - `/home/bullet1517/qemu-9.2.4/build/qemu-system-riscv64`
- OpenSBI:
  - `/home/bullet1517/qemu-9.2.4/pc-bios/opensbi-riscv64-generic-fw_dynamic.bin`
- Kernel:
  - `linux-host-kernel/build-axvisor/arch/riscv/boot/Image`
- Rootfs:
  - `/tmp/axvisor-riscv64-host-rootfs.img`

## 5. 在 guest 里验证模块

进入 guest shell 后执行：

```bash
/root/axvisor/load-axvisor.sh
```

或者手工执行：

```bash
insmod /root/axvisor/axvisor_adapter.ko
dmesg | tail -n 200
```

## 6. 重点观察日志

当前已经加了较多 runtime trace，预期可以在 `dmesg` 里看到这些阶段：

- `AxvisorAdapterModule::init`
- `arch::init_backend`
- `LinuxRuntimeAdapter::run`
- `AxvisorCoreGlue::runtime_start_processor`
- `core_link::boot::boot_run`
- `axvisor_linux_bridge_boot_run`
- `axvisor_core::boot::run`

如果失败，优先记录：

- `insmod` 返回值
- `dmesg` 最后 200 行
- `/tmp/axvisor-riscv64-host-qemu.log`

## 7. 已知故障含义

如果看到这类错误：

- `Unknown symbol rust_helper_get_current`
- `Unknown symbol rust_helper_REFCOUNT_INIT`
- `Unknown symbol _RNvNt...`

它不表示 `axvisor_adapter.ko` 自己缺实现，而是表示：

- 当前启动的宿主内核没有把 Rust runtime 和导出符号编进去
- 最常见原因就是 `CONFIG_RUST` 没开
