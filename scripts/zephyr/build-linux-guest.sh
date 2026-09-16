#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

linux_source="${FH_LINUX_SOURCE:-$FH_REPO_ROOT/linux-host-kernel}"
linux_out="$FH_BUILD_ROOT/linux-guest/kernel"
guest_out="$FH_BUILD_ROOT/guests"
config_fragment="$FH_REPO_ROOT/ports/zephyr/guests/linux.config"

fh_require_file "$linux_source/Makefile"
fh_require_file "$config_fragment"
mkdir -p "$linux_out" "$guest_out"

export KBUILD_BUILD_USER=freehypervisor
export KBUILD_BUILD_HOST=zephyr-port
export KBUILD_BUILD_TIMESTAMP="1970-01-01 00:00:00 UTC"

make -C "$linux_source" O="$linux_out" ARCH=x86_64 \
	KCONFIG_ALLCONFIG="$config_fragment" allnoconfig
make -C "$linux_source" O="$linux_out" ARCH=x86_64 \
	-j"${FH_LINUX_JOBS:-$(nproc)}" bzImage

x86_64-linux-gnu-gcc \
	-Os -nostdlib -static -ffreestanding -fno-pie -no-pie \
	-fno-stack-protector -fno-asynchronous-unwind-tables \
	-Wl,--build-id=none -Wl,-e,_start \
	"$FH_REPO_ROOT/ports/zephyr/guests/linux-init.c" \
	-o "$guest_out/init"

cp "$linux_out/arch/x86/boot/bzImage" "$guest_out/bzImage"
cp "$FH_REPO_ROOT/ports/zephyr/guests/initramfs.list" "$guest_out/initramfs.list"
(
	cd "$guest_out"
	"$linux_out/usr/gen_init_cpio" initramfs.list > initramfs.cpio
)
cp "$FH_REPO_ROOT/ports/zephyr/guests/vm-linux-tcg.toml" \
	"$guest_out/vm-linux-tcg.toml"

file "$guest_out/bzImage" "$guest_out/init" "$guest_out/initramfs.cpio"
wc -c "$guest_out/bzImage" "$guest_out/init" "$guest_out/initramfs.cpio"
