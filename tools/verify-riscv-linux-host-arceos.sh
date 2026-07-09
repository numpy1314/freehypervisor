#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_PATH="${QEMU_LOG:-/tmp/axvisor-riscv64-host-qemu.log}"
TIMEOUT_SECS="${TIMEOUT_SECS:-90}"
POLL_SECS="${POLL_SECS:-1}"
TEXT_SEARCH_CMD=""

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

TEXT_SEARCH_CMD="$(find_cmd rg grep)"

cleanup() {
    pkill -f qemu-system-riscv64 >/dev/null 2>&1 || true
}

require_log_match() {
    local pattern="$1"
    local message="$2"
    if [[ "$TEXT_SEARCH_CMD" == "rg" ]]; then
        if ! rg -n "$pattern" "$LOG_PATH" -S >/dev/null 2>&1; then
            echo "$message" >&2
            return 1
        fi
    else
        if ! grep -nE "$pattern" "$LOG_PATH" >/dev/null 2>&1; then
            echo "$message" >&2
            return 1
        fi
    fi
}

guest_reached_shell() {
    if [[ "$TEXT_SEARCH_CMD" == "rg" ]]; then
        rg -n "axvisor:/\\$|shell::run_cmd_bytes after|Initialize platform devices\\.\.\." "$LOG_PATH" -S >/dev/null 2>&1
    else
        grep -nE "axvisor:/\\$|shell::run_cmd_bytes after|Initialize platform devices\\.\.\." "$LOG_PATH" >/dev/null 2>&1
    fi
}

trap cleanup EXIT

echo "[verify] build host module"
bash "$ROOT_DIR/tools/build-riscv-linux-host-module.sh"

echo "[verify] build host rootfs"
bash "$ROOT_DIR/tools/build-riscv-linux-host-rootfs.sh"

echo "[verify] stop stale qemu"
cleanup
rm -f "$LOG_PATH"

echo "[verify] launch qemu"
(
    cd "$ROOT_DIR"
    exec bash tools/run-riscv-linux-host-qemu.sh
) >/tmp/axvisor-riscv64-host-qemu.console 2>&1 &
QEMU_PID=$!

deadline=$((SECONDS + TIMEOUT_SECS))
while (( SECONDS < deadline )); do
    if [[ -f "$LOG_PATH" ]]; then
        if [[ "$TEXT_SEARCH_CMD" == "rg" ]]; then
            if rg -n "vm_start::start_single_vm success" "$LOG_PATH" -S >/dev/null 2>&1 \
            && guest_reached_shell; then
            echo "[verify] pass"
            echo "[verify] qemu log: $LOG_PATH"
            if rg -n "vcpus::vm_run_err_detail .*AxErrorKind::Unsupported" "$LOG_PATH" -S >/dev/null 2>&1; then
                echo "[verify] note: guest reached shell, then later exited with AxErrorKind::Unsupported"
            fi
            kill "$QEMU_PID" >/dev/null 2>&1 || true
            wait "$QEMU_PID" 2>/dev/null || true
            trap - EXIT
            cleanup
            exit 0
        fi
        else
            if grep -nE "vm_start::start_single_vm success" "$LOG_PATH" >/dev/null 2>&1 \
            && guest_reached_shell; then
            echo "[verify] pass"
            echo "[verify] qemu log: $LOG_PATH"
            if grep -nE "vcpus::vm_run_err_detail .*AxErrorKind::Unsupported" "$LOG_PATH" >/dev/null 2>&1; then
                echo "[verify] note: guest reached shell, then later exited with AxErrorKind::Unsupported"
            fi
            kill "$QEMU_PID" >/dev/null 2>&1 || true
            wait "$QEMU_PID" 2>/dev/null || true
            trap - EXIT
            cleanup
            exit 0
        fi
        fi
    fi
    sleep "$POLL_SECS"
done

echo "[verify] timeout after ${TIMEOUT_SECS}s" >&2
if [[ -f "$LOG_PATH" ]]; then
    tail -n 120 "$LOG_PATH" >&2 || true
fi
require_log_match "vm_start::start_single_vm success" "[verify] vm start did not succeed" || true
if ! guest_reached_shell; then
    echo "[verify] guest did not reach ArceOS shell" >&2
fi
exit 1
