#!/usr/bin/env bash
set -euo pipefail

FH_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FH_WORKSPACE="$(cd "$FH_REPO_ROOT/.." && pwd)"
FH_ZEPHYR_BASE="${ZEPHYR_BASE:-$FH_WORKSPACE/zephyr-4.4.0}"
FH_VENV="${FH_ZEPHYR_VENV:-$FH_WORKSPACE/zephyr-venv}"
FH_WEST="${WEST:-$FH_VENV/bin/west}"
FH_BUILD_ROOT="$FH_REPO_ROOT/build/zephyr"
FH_ARTIFACTS="$FH_REPO_ROOT/artifacts/zephyr"
FH_CORE_SOURCE="${FH_CORE_SOURCE:-$FH_WORKSPACE/tgoskits-axvisor-core-reference}"
FH_CORE_COMMIT="534de06e3855a31ff2d74e9faa75c6cdcc2cf8d8"
FH_QEMU_PATCHED="$FH_BUILD_ROOT/qemu-tcg/qemu-system-x86_64"
if [[ -n "${FH_QEMU_BIN:-}" ]]; then
    FH_QEMU="$FH_QEMU_BIN"
elif [[ -x "$FH_QEMU_PATCHED" ]]; then
    FH_QEMU="$FH_QEMU_PATCHED"
else
    FH_QEMU="qemu-system-x86_64"
fi

mkdir -p "$FH_BUILD_ROOT" "$FH_ARTIFACTS"
export ZEPHYR_BASE="$FH_ZEPHYR_BASE"
export PATH="/root/.cargo/bin:$FH_VENV/bin:$PATH"
export ZEPHYR_TOOLCHAIN_VARIANT="${ZEPHYR_TOOLCHAIN_VARIANT:-host}"

fh_require_file() {
    if [[ ! -f "$1" ]]; then
        echo "missing required file: $1" >&2
        exit 1
    fi
}

fh_require_nested_tcg_qemu() {
    if [[ -n "${FH_QEMU_BIN:-}" ]]; then
        fh_require_file "$FH_QEMU"
        return
    fi
    if [[ ! -x "$FH_QEMU_PATCHED" ]]; then
        "$FH_REPO_ROOT/scripts/zephyr/build-qemu-tcg.sh"
    fi
    FH_QEMU="$FH_QEMU_PATCHED"
}

fh_run_qemu() {
    local elf="$1"
    local log="$2"
    local cpu="${3:-max}"
    local accel="${4:-tcg}"
    local timeout_seconds="${FH_QEMU_TIMEOUT:-45}"
    local zephyr_dir
    local build_dir
    local locore
    local main_image

    fh_require_file "$elf"
    zephyr_dir="$(dirname "$elf")"
    build_dir="$(dirname "$zephyr_dir")"
    cmake --build "$build_dir" --target qemu_kernel_target >/dev/null
    locore="$zephyr_dir/zephyr-qemu-locore.elf"
    main_image="$zephyr_dir/zephyr-qemu-main.elf"
    fh_require_file "$locore"
    fh_require_file "$main_image"
    set +e
    timeout --signal=TERM "$timeout_seconds" \
        "$FH_QEMU" \
        -machine "q35,accel=$accel" \
        -cpu "$cpu,mmx,mmxext,sse,sse2" \
        -smp cpus=2 \
        -m 64M \
        -nographic \
        -no-reboot \
        -machine acpi=off \
        -net none \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        -device "loader,file=$main_image" \
        -kernel "$locore" 2>&1 | tee "$log"
    local qemu_status="${PIPESTATUS[0]}"
    set -e

    # qemu_x86_64 may return 1 after Zephyr requests a cold reboot under
    # -no-reboot.  Accept that controlled termination only after the guest
    # emitted one of this harness's terminal result markers; each caller then
    # checks the exact expected PASS marker.
    if [[ "$qemu_status" -eq 1 ]] &&
       grep -Eq '(FH_|BASELINE_)RESULT.*=(PASS|FAIL|BLOCKED)' "$log"; then
        qemu_status=0
    fi
    if [[ "$qemu_status" -ne 0 && "$qemu_status" -ne 124 ]]; then
        echo "qemu failed with status $qemu_status" >&2
        return "$qemu_status"
    fi
}
