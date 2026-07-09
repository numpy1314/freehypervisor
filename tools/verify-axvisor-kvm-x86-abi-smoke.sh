#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-/tmp/axvisor-kvm-x86-abi-smoke-build}"
RUN_DIR="${RUN_DIR:-$(mktemp -d /tmp/axvisor-kvm-x86-abi-smoke.XXXXXX)}"
QEMU_BIN="${QEMU_BIN:-/home/bullet1517/qemu-9.2.4/build/qemu-system-x86_64}"
BUSYBOX="${BUSYBOX:-/usr/bin/busybox}"
QEMU_ACCEL="${QEMU_ACCEL:-kvm}"
QEMU_CPU="${QEMU_CPU:-}"
QEMU_MEM="${QEMU_MEM:-1024M}"
QEMU_SMP="${QEMU_SMP:-1}"
TIMEOUT_SECS="${TIMEOUT_SECS:-180}"
POLL_SECS="${POLL_SECS:-1}"
SKIP_BUILD="${SKIP_BUILD:-0}"
AXVISOR_KVM_DEV_NAME="${AXVISOR_KVM_DEV_NAME:-kvm}"

KO_PATH="$BUILD_DIR/drivers/virt/axvisor/axvisor_kvm.ko"
KERNEL_IMAGE="$BUILD_DIR/arch/x86/boot/bzImage"
API_SMOKE_BIN="$RUN_DIR/axvisor-kvm-api-smoke"
MEM_VCPU_SMOKE_BIN="$RUN_DIR/axvisor-kvm-mem-vcpu-smoke"
CONCURRENT_RUN_SMOKE_BIN="$RUN_DIR/axvisor-kvm-concurrent-run-smoke"
NEGATIVE_SMOKE_BIN="$RUN_DIR/axvisor-kvm-negative-smoke"
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

build_smoke_binaries() {
    echo "[verify] build KVM ABI smoke binaries"
    cc -static -O2 -Wall -Wextra \
        -o "$API_SMOKE_BIN" \
        "$ROOT_DIR/tools/axvisor-kvm-api-smoke.c"
    cc -static -O2 -Wall -Wextra \
        -o "$MEM_VCPU_SMOKE_BIN" \
        "$ROOT_DIR/tools/axvisor-kvm-mem-vcpu-smoke.c"
    cc -static -O2 -Wall -Wextra -pthread \
        -o "$CONCURRENT_RUN_SMOKE_BIN" \
        "$ROOT_DIR/tools/axvisor-kvm-concurrent-run-smoke.c"
    cc -static -O2 -Wall -Wextra \
        -o "$NEGATIVE_SMOKE_BIN" \
        "$ROOT_DIR/tools/axvisor-kvm-negative-smoke.c"
    need_file "$API_SMOKE_BIN"
    need_file "$MEM_VCPU_SMOKE_BIN"
    need_file "$CONCURRENT_RUN_SMOKE_BIN"
    need_file "$NEGATIVE_SMOKE_BIN"
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
    cp "$API_SMOKE_BIN" "$INITRAMFS_DIR/root/axvisor-kvm-api-smoke"
    cp "$MEM_VCPU_SMOKE_BIN" "$INITRAMFS_DIR/root/axvisor-kvm-mem-vcpu-smoke"
    cp "$CONCURRENT_RUN_SMOKE_BIN" "$INITRAMFS_DIR/root/axvisor-kvm-concurrent-run-smoke"
    cp "$NEGATIVE_SMOKE_BIN" "$INITRAMFS_DIR/root/axvisor-kvm-negative-smoke"
    chmod +x "$INITRAMFS_DIR/root/axvisor-kvm-api-smoke"
    chmod +x "$INITRAMFS_DIR/root/axvisor-kvm-mem-vcpu-smoke"
    chmod +x "$INITRAMFS_DIR/root/axvisor-kvm-concurrent-run-smoke"
    chmod +x "$INITRAMFS_DIR/root/axvisor-kvm-negative-smoke"

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

fail() {
    echo "AXVISOR_KVM_ABI_SMOKE_FAIL=\$1"
    dmesg | tail -n 260 || true
    finish
}

mount -t proc proc /proc || true
mount -t sysfs sysfs /sys || true
mount -t devtmpfs devtmpfs /dev || true
mkdir -p /dev /proc /sys /tmp /root

echo "[guest] uname -a"
uname -a
echo "[guest] insmod axvisor_kvm.ko dev_name=\$AXVISOR_KVM_DEV_NAME"
if ! insmod /root/axvisor_kvm.ko dev_name="\$AXVISOR_KVM_DEV_NAME"; then
    fail "insmod"
fi

if [ ! -e "\$AXVISOR_KVM_DEV" ]; then
    ls -l /dev || true
    fail "missing-dev-kvm"
fi
ls -l "\$AXVISOR_KVM_DEV" || true

echo "[guest] run KVM API smoke"
if ! KVM_DEV="\$AXVISOR_KVM_DEV" /root/axvisor-kvm-api-smoke; then
    fail "api-smoke"
fi

echo "[guest] run KVM mem/vcpu smoke"
if ! KVM_DEV="\$AXVISOR_KVM_DEV" /root/axvisor-kvm-mem-vcpu-smoke; then
    fail "mem-vcpu-smoke"
fi

echo "[guest] run KVM concurrent KVM_RUN smoke"
if ! KVM_DEV="\$AXVISOR_KVM_DEV" /root/axvisor-kvm-concurrent-run-smoke; then
    fail "concurrent-run-smoke"
fi

echo "[guest] run KVM negative smoke"
if ! KVM_DEV="\$AXVISOR_KVM_DEV" /root/axvisor-kvm-negative-smoke; then
    fail "negative-smoke"
fi

echo "AXVISOR_KVM_ABI_SMOKE_QEMU_PASS=1"
dmesg | tail -n 200 || true
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
        if grep -q "AXVISOR_KVM_ABI_SMOKE_QEMU_PASS=1" "$QEMU_LOG"; then
            echo "[verify] pass"
            cleanup
            return 0
        fi
        if grep -q "AXVISOR_KVM_ABI_SMOKE_FAIL=" "$QEMU_LOG"; then
            echo "[verify] guest reported failure" >&2
            tail -n 260 "$QEMU_LOG" >&2 || true
            cleanup
            return 1
        fi
        if [[ -n "$QEMU_PID" ]] && ! kill -0 "$QEMU_PID" >/dev/null 2>&1; then
            wait "$QEMU_PID" || true
            QEMU_PID=""
            # QEMU can exit immediately after guest poweroff while the file
            # backend still has the last serial bytes in flight.
            sleep 1
            if grep -q "AXVISOR_KVM_ABI_SMOKE_QEMU_PASS=1" "$QEMU_LOG"; then
                echo "[verify] pass"
                return 0
            fi
            echo "[verify] qemu exited before pass marker" >&2
            tail -n 260 "$QEMU_LOG" >&2 || true
            return 1
        fi
        sleep "$POLL_SECS"
    done

    echo "[verify] timeout after ${TIMEOUT_SECS}s waiting for pass marker" >&2
    tail -n 320 "$QEMU_LOG" >&2 || true
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
build_smoke_binaries
prepare_initramfs
launch_qemu
wait_for_result

echo "[verify] run dir: $RUN_DIR"
echo "[verify] qemu log: $QEMU_LOG"
echo "[verify] kernel image: $KERNEL_IMAGE"
echo "[verify] module: $KO_PATH"
