#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_DIR="$ROOT_DIR/linux-host-kernel"
BUILD_DIR="${BUILD_DIR:-/tmp/axvisor-kvm-x86-firecracker-init-build}"
RUN_DIR="${RUN_DIR:-$(mktemp -d /tmp/axvisor-kvm-x86-firecracker-init-smoke.XXXXXX)}"
QEMU_BIN="${QEMU_BIN:-/home/bullet1517/qemu-9.2.4/build/qemu-system-x86_64}"
BUSYBOX="${BUSYBOX:-/usr/bin/busybox}"
QEMU_ACCEL="${QEMU_ACCEL:-tcg}"
QEMU_CPU="${QEMU_CPU:-}"
QEMU_MEM="${QEMU_MEM:-1024M}"
QEMU_SMP="${QEMU_SMP:-1}"
TIMEOUT_SECS="${TIMEOUT_SECS:-180}"
POLL_SECS="${POLL_SECS:-1}"
SKIP_BUILD="${SKIP_BUILD:-0}"
AXVISOR_KVM_DEV_NAME="${AXVISOR_KVM_DEV_NAME:-kvm}"

KO_PATH="$BUILD_DIR/drivers/virt/axvisor/axvisor_kvm.ko"
KERNEL_IMAGE="$BUILD_DIR/arch/x86/boot/bzImage"
SMOKE_BIN="$RUN_DIR/axvisor-kvm-firecracker-init-smoke"
INITRAMFS_DIR="$RUN_DIR/initramfs"
INITRAMFS_IMG="$RUN_DIR/initramfs.cpio.gz"
QEMU_LOG="$RUN_DIR/qemu.log"
QEMU_PID=""

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "missing command: $1" >&2
        exit 1
    }
}

need_file() {
    [[ -f "$1" ]] || {
        echo "required file not found: $1" >&2
        exit 1
    }
}

cleanup() {
    if [[ -n "$QEMU_PID" ]]; then
        kill "$QEMU_PID" >/dev/null 2>&1 || true
        wait "$QEMU_PID" 2>/dev/null || true
        QEMU_PID=""
    fi
}

build_kernel_and_module() {
    if [[ "$SKIP_BUILD" == "1" ]]; then
        echo "[verify] skip build"
    else
        echo "[verify] build x86_64 kernel image and axvisor_kvm.ko"
        BUILD_DIR="$BUILD_DIR" \
        AXVISOR_KVM_BACKEND=1 \
        AXVISOR_KVM_X86_BRIDGE=1 \
        AXVISOR_KVM_BUILD_BZIMAGE=1 \
            bash "$ROOT_DIR/tools/build-axvisor-kvm-x86-module.sh"
    fi

    need_file "$KERNEL_IMAGE"
    need_file "$KO_PATH"
}

build_smoke_binary() {
    echo "[verify] build Firecracker init ABI smoke"
    cc -static -O2 -Wall -Wextra \
        -o "$SMOKE_BIN" \
        "$ROOT_DIR/tools/axvisor-kvm-firecracker-init-smoke.c"
    need_file "$SMOKE_BIN"
}

prepare_initramfs() {
    local applet

    echo "[verify] prepare initramfs: $INITRAMFS_IMG"
    rm -rf "$INITRAMFS_DIR"
    mkdir -p "$INITRAMFS_DIR/bin" "$INITRAMFS_DIR/dev" "$INITRAMFS_DIR/proc" \
        "$INITRAMFS_DIR/root" "$INITRAMFS_DIR/sys" "$INITRAMFS_DIR/tmp"

    cp "$BUSYBOX" "$INITRAMFS_DIR/bin/busybox"
    chmod +x "$INITRAMFS_DIR/bin/busybox"
    for applet in sh mount uname dmesg insmod ls sleep mkdir cat grep sync \
        poweroff reboot tail; do
        ln -s busybox "$INITRAMFS_DIR/bin/$applet"
    done

    cp "$KO_PATH" "$INITRAMFS_DIR/root/axvisor_kvm.ko"
    cp "$SMOKE_BIN" "$INITRAMFS_DIR/root/axvisor-kvm-firecracker-init-smoke"
    chmod +x "$INITRAMFS_DIR/root/axvisor-kvm-firecracker-init-smoke"

    cat >"$INITRAMFS_DIR/init" <<EOF
#!/bin/sh
set -eu

export PATH=/bin:/sbin:/usr/bin:/usr/sbin
AXVISOR_KVM_DEV_NAME="$AXVISOR_KVM_DEV_NAME"
AXVISOR_KVM_DEV="/dev/\$AXVISOR_KVM_DEV_NAME"

finish() {
    sync || true
    poweroff -f || reboot -f || sleep 3600
}

mount -t proc proc /proc || true
mount -t sysfs sysfs /sys || true
mount -t devtmpfs devtmpfs /dev || true
mkdir -p /dev /proc /sys /tmp /root

echo "[guest] uname -a"
uname -a
echo "[guest] insmod axvisor_kvm.ko dev_name=\$AXVISOR_KVM_DEV_NAME"
if ! insmod /root/axvisor_kvm.ko dev_name="\$AXVISOR_KVM_DEV_NAME"; then
    echo "AXVISOR_KVM_FIRECRACKER_INIT_SMOKE_FAIL=insmod"
    dmesg | tail -n 200 || true
    finish
fi

echo "[guest] device nodes"
ls -l "\$AXVISOR_KVM_DEV" || true

echo "[guest] run Firecracker init ABI smoke"
if KVM_DEV="\$AXVISOR_KVM_DEV" /root/axvisor-kvm-firecracker-init-smoke; then
    echo "AXVISOR_KVM_X86_FIRECRACKER_INIT_QEMU_PASS=1"
else
    rc="$?"
    echo "AXVISOR_KVM_FIRECRACKER_INIT_SMOKE_FAIL=smoke rc=\$rc"
    dmesg | tail -n 260 || true
    finish
fi

echo "[guest] dmesg tail"
dmesg | tail -n 160 || true
finish
EOF
    chmod +x "$INITRAMFS_DIR/init"

    (
        cd "$INITRAMFS_DIR"
        find . -print0 | cpio --null -o --format=newc | gzip -9 >"$INITRAMFS_IMG"
    ) >/dev/null
    need_file "$INITRAMFS_IMG"
}

launch_qemu() {
    local cpu_arg

    : >"$QEMU_LOG"
    if [[ "$QEMU_ACCEL" == "kvm" && ! -e /dev/kvm ]]; then
        echo "QEMU_ACCEL=kvm requested but /dev/kvm does not exist on this host" >&2
        exit 1
    fi

    if [[ -n "$QEMU_CPU" ]]; then
        cpu_arg="$QEMU_CPU"
    elif [[ "$QEMU_ACCEL" == "kvm" ]]; then
        cpu_arg="host"
    else
        cpu_arg="max"
    fi

    echo "[verify] launch qemu accel=$QEMU_ACCEL cpu=$cpu_arg"
    "$QEMU_BIN" \
        -nodefaults \
        -no-reboot \
        -display none \
        -monitor none \
        -serial "file:$QEMU_LOG" \
        -m "$QEMU_MEM" \
        -smp "$QEMU_SMP" \
        -accel "$QEMU_ACCEL" \
        -cpu "$cpu_arg" \
        -kernel "$KERNEL_IMAGE" \
        -initrd "$INITRAMFS_IMG" \
        -append "console=ttyS0 earlyprintk=serial panic=-1 oops=panic nokaslr" &
    QEMU_PID=$!
}

wait_for_result() {
    local deadline

    deadline=$((SECONDS + TIMEOUT_SECS))
    while (( SECONDS < deadline )); do
        if grep -q "AXVISOR_KVM_X86_FIRECRACKER_INIT_QEMU_PASS=1" "$QEMU_LOG"; then
            echo "[verify] pass"
            cleanup
            return 0
        fi
        if grep -q "AXVISOR_KVM_FIRECRACKER_INIT_SMOKE_FAIL=" "$QEMU_LOG"; then
            echo "[verify] guest reported failure" >&2
            tail -n 220 "$QEMU_LOG" >&2 || true
            cleanup
            return 1
        fi
        if [[ -n "$QEMU_PID" ]] && ! kill -0 "$QEMU_PID" >/dev/null 2>&1; then
            wait "$QEMU_PID" || true
            QEMU_PID=""
            if grep -q "AXVISOR_KVM_X86_FIRECRACKER_INIT_QEMU_PASS=1" "$QEMU_LOG"; then
                echo "[verify] pass"
                return 0
            fi
            echo "[verify] qemu exited before pass marker" >&2
            tail -n 220 "$QEMU_LOG" >&2 || true
            return 1
        fi
        sleep "$POLL_SECS"
    done

    echo "[verify] timeout after ${TIMEOUT_SECS}s waiting for pass marker" >&2
    tail -n 260 "$QEMU_LOG" >&2 || true
    cleanup
    return 1
}

need_cmd bash
need_cmd cc
need_cmd cpio
need_cmd find
need_cmd gzip
need_cmd grep
need_cmd ln
need_cmd tail
need_file "$QEMU_BIN"
need_file "$BUSYBOX"

trap cleanup EXIT
mkdir -p "$RUN_DIR"

build_kernel_and_module
build_smoke_binary
prepare_initramfs
launch_qemu
wait_for_result

echo "[verify] run dir: $RUN_DIR"
echo "[verify] qemu log: $QEMU_LOG"
echo "[verify] kernel image: $KERNEL_IMAGE"
echo "[verify] module: $KO_PATH"
