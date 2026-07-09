#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

BASE_GUEST_ROOTFS_IMG="${BASE_GUEST_ROOTFS_IMG:-$ROOT_DIR/ivans-asterinas-axvisor-host/target/axvisor/images/qemu_riscv64_linux/rootfs.img}"
SMOKE_INIT_TEMPLATE="${SMOKE_INIT_TEMPLATE:-$ROOT_DIR/tools/axvisor-guest-linux-smoke-init.sh}"
SMOKE_INIT_PATH_IN_GUEST="${SMOKE_INIT_PATH_IN_GUEST:-/init}"
SMOKE_RESULT_PATH_IN_GUEST="${SMOKE_RESULT_PATH_IN_GUEST:-/axvisor-smoke-result.txt}"
SMOKE_LOG_PATH_IN_GUEST="${SMOKE_LOG_PATH_IN_GUEST:-/axvisor-smoke.log}"
RUN_DIR="${RUN_DIR:-$(mktemp -d /tmp/axvisor-riscv64-linux-guest-smoke.XXXXXX)}"
HOST_ROOTFS_IMG="${HOST_ROOTFS_IMG:-$(mktemp /tmp/axvisor-riscv64-host-rootfs.smoke.XXXXXX.img)}"
SMOKE_GUEST_ROOTFS_IMG="${SMOKE_GUEST_ROOTFS_IMG:-$(mktemp /tmp/axvisor-qemu-riscv64-linux-guest-rootfs.smoke.XXXXXX.img)}"
QEMU_LOG="${QEMU_LOG:-$RUN_DIR/qemu.log}"
HOST_HVC_LOG="${HOST_HVC_LOG:-$RUN_DIR/hvc.log}"
QEMU_CONSOLE_LOG="${QEMU_CONSOLE_LOG:-$RUN_DIR/console.log}"
RESULT_EXTRACT_PATH="${RESULT_EXTRACT_PATH:-$RUN_DIR/result.txt}"
GUEST_LOG_EXTRACT_PATH="${GUEST_LOG_EXTRACT_PATH:-$RUN_DIR/guest.log}"
TIMEOUT_SECS="${TIMEOUT_SECS:-180}"
POLL_SECS="${POLL_SECS:-1}"
AXVISOR_AUTOBOOT_DELAY_SECS="${AXVISOR_AUTOBOOT_DELAY_SECS:-20}"

QEMU_PID=""
TEXT_SEARCH_CMD=""

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "missing command: $1" >&2
        exit 1
    }
}

find_cmd() {
    local cmd
    for cmd in "$@"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            echo "$cmd"
            return 0
        fi
    done
    return 1
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

runtime_log_has() {
    local pattern="$1"
    if [[ "$TEXT_SEARCH_CMD" == "rg" ]]; then
        rg -n "$pattern" "$QEMU_LOG" "$HOST_HVC_LOG" -S >/dev/null 2>&1
    else
        grep -nE "$pattern" "$QEMU_LOG" "$HOST_HVC_LOG" >/dev/null 2>&1
    fi
}

debugfs_file_exists() {
    local image="$1"
    local guest_path="$2"

    if [[ "$TEXT_SEARCH_CMD" == "rg" ]]; then
        debugfs -R "stat $guest_path" "$image" 2>/dev/null | rg -n "^Inode:" -S >/dev/null 2>&1
    else
        debugfs -R "stat $guest_path" "$image" 2>/dev/null | grep -nE "^Inode:" >/dev/null 2>&1
    fi
}

debugfs_file_size() {
    local image="$1"
    local guest_path="$2"

    debugfs -R "stat $guest_path" "$image" 2>/dev/null \
        | awk '/Size:/ { for (i = 1; i <= NF; i++) if ($i == "Size:") { print $(i + 1); exit } }'
}

guest_result_exists() {
    debugfs_file_exists "$SMOKE_GUEST_ROOTFS_IMG" "$SMOKE_RESULT_PATH_IN_GUEST"
}

dump_debugfs_file() {
    local image="$1"
    local guest_path="$2"
    local out_path="$3"

    rm -f "$out_path"
    debugfs -R "dump $guest_path $out_path" "$image" >/dev/null 2>&1 || true
    [[ -f "$out_path" ]]
}

print_debugfs_file() {
    local image="$1"
    local guest_path="$2"

    if debugfs_file_exists "$image" "$guest_path"; then
        debugfs -R "cat $guest_path" "$image" 2>/dev/null || true
    fi
}

extract_failure_context() {
    echo "[verify] guest smoke result not available, dumping host autostart context" >&2
    echo "[verify] /root/axvisor/autostart.log" >&2
    print_debugfs_file "$HOST_ROOTFS_IMG" "/root/axvisor/autostart.log" >&2
    echo "[verify] /root/axvisor/prestart-dmesg.grep" >&2
    print_debugfs_file "$HOST_ROOTFS_IMG" "/root/axvisor/prestart-dmesg.grep" >&2
    echo "[verify] /root/axvisor/poststart-dmesg.log tail" >&2
    print_debugfs_file "$HOST_ROOTFS_IMG" "/root/axvisor/poststart-dmesg.log" | tail -n 120 >&2 || true
    echo "[verify] guest smoke log" >&2
    print_debugfs_file "$SMOKE_GUEST_ROOTFS_IMG" "$SMOKE_LOG_PATH_IN_GUEST" >&2
    if [[ -f "$QEMU_LOG" ]]; then
        echo "[verify] qemu log tail" >&2
        tail -n 120 "$QEMU_LOG" >&2 || true
    fi
    if [[ -f "$HOST_HVC_LOG" ]]; then
        echo "[verify] host hvc log tail" >&2
        tail -n 160 "$HOST_HVC_LOG" >&2 || true
    fi
}

prepare_smoke_guest_rootfs() {
    local expected_size actual_size injected_tmp

    echo "[verify] prepare smoke guest rootfs: $SMOKE_GUEST_ROOTFS_IMG"
    cp "$BASE_GUEST_ROOTFS_IMG" "$SMOKE_GUEST_ROOTFS_IMG"
    e2fsck -fy "$SMOKE_GUEST_ROOTFS_IMG" >/dev/null
    debugfs -w -R "rm $SMOKE_INIT_PATH_IN_GUEST" \
        "$SMOKE_GUEST_ROOTFS_IMG" >/dev/null 2>&1 || true
    debugfs -w -R "write $SMOKE_INIT_TEMPLATE $SMOKE_INIT_PATH_IN_GUEST" \
        "$SMOKE_GUEST_ROOTFS_IMG" >/dev/null
    e2fsck -fy "$SMOKE_GUEST_ROOTFS_IMG" >/dev/null

    expected_size="$(wc -c < "$SMOKE_INIT_TEMPLATE")"
    actual_size="$(debugfs_file_size "$SMOKE_GUEST_ROOTFS_IMG" "$SMOKE_INIT_PATH_IN_GUEST")"
    if [[ "$actual_size" != "$expected_size" ]]; then
        echo "[verify] smoke init injection failed: expected_size=$expected_size actual_size=${actual_size:-missing}" >&2
        debugfs -R "stat $SMOKE_INIT_PATH_IN_GUEST" "$SMOKE_GUEST_ROOTFS_IMG" >&2 || true
        exit 1
    fi

    injected_tmp="$(mktemp /tmp/axvisor-smoke-init-injected.XXXXXX)"
    if ! dump_debugfs_file "$SMOKE_GUEST_ROOTFS_IMG" "$SMOKE_INIT_PATH_IN_GUEST" "$injected_tmp" ||
       ! cmp -s "$SMOKE_INIT_TEMPLATE" "$injected_tmp"; then
        echo "[verify] smoke init injection content mismatch" >&2
        debugfs -R "stat $SMOKE_INIT_PATH_IN_GUEST" "$SMOKE_GUEST_ROOTFS_IMG" >&2 || true
        rm -f "$injected_tmp"
        exit 1
    fi
    rm -f "$injected_tmp"
}

need_cmd bash
need_cmd debugfs
need_cmd e2fsck
need_cmd cmp
TEXT_SEARCH_CMD="$(find_cmd rg grep)"
need_cmd "$TEXT_SEARCH_CMD"
need_file "$BASE_GUEST_ROOTFS_IMG"
need_file "$SMOKE_INIT_TEMPLATE"
mkdir -p "$RUN_DIR"

trap cleanup EXIT

echo "[verify] build host module"
bash "$ROOT_DIR/tools/build-riscv-linux-host-module.sh"

prepare_smoke_guest_rootfs

echo "[verify] build host rootfs: $HOST_ROOTFS_IMG"
(
    cd "$ROOT_DIR"
    ROOTFS_IMG="$HOST_ROOTFS_IMG" \
    GUEST_KIND=linux \
    GUEST_ROOTFS="$SMOKE_GUEST_ROOTFS_IMG" \
    ENABLE_AXVISOR_AUTOBOOT=1 \
    AXVISOR_AUTOBOOT_DELAY_SECS="$AXVISOR_AUTOBOOT_DELAY_SECS" \
    AXVISOR_RELEASE_REGISTERED_PASSTHROUGH_MMIO=1 \
    GUEST_LINUX_BOOT_MODE=smoke \
    GUEST_LINUX_SMOKE_INIT_PATH="$SMOKE_INIT_PATH_IN_GUEST" \
    bash tools/build-riscv-linux-host-rootfs.sh
)

rm -f "$QEMU_LOG" "$HOST_HVC_LOG" "$QEMU_CONSOLE_LOG"

echo "[verify] launch qemu"
(
    cd "$ROOT_DIR"
    ROOTFS_IMG="$HOST_ROOTFS_IMG" \
    GUEST_ROOTFS_IMG="$SMOKE_GUEST_ROOTFS_IMG" \
    QEMU_LOG="$QEMU_LOG" \
    HOST_HVC_LOG="$HOST_HVC_LOG" \
    HOST_CONSOLE_MODE=hvc0 \
    bash tools/run-riscv-linux-host-qemu.sh
) >"$QEMU_CONSOLE_LOG" 2>&1 &
QEMU_PID=$!

deadline=$((SECONDS + TIMEOUT_SECS))
guest_shutdown_seen=0
guest_result_seen=0
while (( SECONDS < deadline )); do
    if guest_result_exists; then
        guest_result_seen=1
        break
    fi
    if runtime_log_has "vcpus::exit_reason system_down"; then
        guest_shutdown_seen=1
        break
    fi
    sleep "$POLL_SECS"
done

if [[ "$guest_shutdown_seen" != "1" && "$guest_result_seen" != "1" ]]; then
    echo "[verify] timeout after ${TIMEOUT_SECS}s waiting for guest result or shutdown" >&2
    extract_failure_context
    exit 1
fi

if [[ "$guest_result_seen" == "1" ]]; then
    echo "[verify] guest smoke result detected"
elif [[ "$guest_shutdown_seen" == "1" ]]; then
    echo "[verify] guest requested shutdown"
fi
cleanup
sleep 1

dump_debugfs_file "$SMOKE_GUEST_ROOTFS_IMG" "$SMOKE_RESULT_PATH_IN_GUEST" "$RESULT_EXTRACT_PATH" || true
dump_debugfs_file "$SMOKE_GUEST_ROOTFS_IMG" "$SMOKE_LOG_PATH_IN_GUEST" "$GUEST_LOG_EXTRACT_PATH" || true

if [[ ! -f "$RESULT_EXTRACT_PATH" ]]; then
    echo "[verify] smoke result file not found: $SMOKE_RESULT_PATH_IN_GUEST" >&2
    extract_failure_context
    exit 1
fi

if [[ "$TEXT_SEARCH_CMD" == "rg" ]]; then
    if ! rg -n "^AXVISOR_SMOKE_PASS=1$" "$RESULT_EXTRACT_PATH" -S >/dev/null 2>&1; then
        echo "[verify] smoke result did not report pass" >&2
        cat "$RESULT_EXTRACT_PATH" >&2
        extract_failure_context
        exit 1
    fi
else
    if ! grep -nE "^AXVISOR_SMOKE_PASS=1$" "$RESULT_EXTRACT_PATH" >/dev/null 2>&1; then
        echo "[verify] smoke result did not report pass" >&2
        cat "$RESULT_EXTRACT_PATH" >&2
        extract_failure_context
        exit 1
    fi
fi

if [[ "$TEXT_SEARCH_CMD" == "rg" ]]; then
    if ! rg -n "^HAS_DEV_VDA=1$|^HAS_SYS_BLOCK_VDA=1$" "$RESULT_EXTRACT_PATH" -S >/dev/null 2>&1; then
        echo "[verify] guest smoke result did not observe /dev/vda or /sys/block/vda" >&2
        cat "$RESULT_EXTRACT_PATH" >&2
        extract_failure_context
        exit 1
    fi
else
    if ! grep -nE "^HAS_DEV_VDA=1$|^HAS_SYS_BLOCK_VDA=1$" "$RESULT_EXTRACT_PATH" >/dev/null 2>&1; then
        echo "[verify] guest smoke result did not observe /dev/vda or /sys/block/vda" >&2
        cat "$RESULT_EXTRACT_PATH" >&2
        extract_failure_context
        exit 1
    fi
fi

echo "[verify] pass"
echo "[verify] run dir: $RUN_DIR"
echo "[verify] smoke result: $RESULT_EXTRACT_PATH"
echo "[verify] guest smoke log: $GUEST_LOG_EXTRACT_PATH"
echo "[verify] host rootfs: $HOST_ROOTFS_IMG"
echo "[verify] guest rootfs: $SMOKE_GUEST_ROOTFS_IMG"
cat "$RESULT_EXTRACT_PATH"
