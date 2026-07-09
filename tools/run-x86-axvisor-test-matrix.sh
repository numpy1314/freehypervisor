#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MATRIX_ID="${MATRIX_ID:-$(date +%Y%m%d-%H%M%S)}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/output/x86-axvisor-test-matrix-$MATRIX_ID}"
case "$OUT_DIR" in
    /*) ;;
    *) OUT_DIR="$ROOT_DIR/$OUT_DIR" ;;
esac
BUILD_DIR="${BUILD_DIR:-/tmp/axvisor-x86-test-matrix-build}"
KVM_BUILD_DIR="${KVM_BUILD_DIR:-/tmp/axvisor-kvm-x86-test-matrix-build}"
TIMEOUT_SECS="${TIMEOUT_SECS:-240}"
QEMU_ACCEL="${QEMU_ACCEL:-kvm}"
QEMU_CPU="${QEMU_CPU:-}"
FIRECRACKER_BIN="${FIRECRACKER_BIN:-/tmp/firecracker-gnu-target/x86_64-unknown-linux-gnu/debug/firecracker}"
NATIVE_SKIP_BUILD="${NATIVE_SKIP_BUILD:-0}"
KVM_INIT_SKIP_BUILD="${KVM_INIT_SKIP_BUILD:-0}"
FIRECRACKER_SKIP_BUILD="${FIRECRACKER_SKIP_BUILD:-1}"

SUMMARY="$OUT_DIR/summary.txt"
STATUS="pass"

need_file() {
    [[ -f "$1" ]] || {
        echo "required file not found: $1" >&2
        exit 1
    }
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "missing command: $1" >&2
        exit 1
    }
}

record() {
    printf '%s\n' "$*" | tee -a "$SUMMARY"
}

run_case() {
    local case_id="$1"
    local description="$2"
    shift 2

    local case_dir="$OUT_DIR/$case_id"
    local log="$case_dir/run.out"
    mkdir -p "$case_dir"

    record "CASE=$case_id"
    record "DESCRIPTION=$description"
    record "LOG=$log"

    if "$@" >"$log" 2>&1; then
        record "STATUS=pass"
    else
        local rc=$?
        record "STATUS=fail"
        record "RC=$rc"
        STATUS="fail"
        echo "[matrix] $case_id failed; tail follows" >&2
        tail -n 220 "$log" >&2 || true
        return "$rc"
    fi
    record
}

copy_if_exists() {
    local src="$1"
    local dst="$2"
    if [[ -e "$src" ]]; then
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst"
    fi
}

write_readme() {
    cat >"$OUT_DIR/README.md" <<EOF
# x86 AxVisor Test Matrix Evidence

Matrix ID: \`$MATRIX_ID\`

Result: \`$STATUS\`

This directory records an x86-only AxVisor validation run.

Validated layers:

- Layer1: x86 Linux host -> AxVisor Linux-host adapter -> x86 Linux guest.
- Layer2: unmodified x86 Firecracker -> \`/dev/kvm\` from \`axvisor_kvm.ko\` -> AxVisor backend -> x86 Linux guest.

Primary files:

- \`summary.txt\`: case-level pass/fail summary.
- \`X86-L1-ROOTFS/\`: ext4 rootfs guest evidence.
- \`X86-L1-INITRAMFS/\`: initramfs guest evidence.
- \`X86-L2-KVM-INIT/\`: Firecracker-required KVM init ABI smoke evidence.
- \`X86-L2-FC-RUN/\`: unmodified Firecracker boot evidence.
- \`X86-L2-FC-ROOTFS-TINY/\`: unmodified Firecracker rootfs boot with a
  static tiny init that proves ext4 root mount and first userspace execution.
- \`SHA256SUMS\`: checksums for preserved evidence.

Scope boundary:

- This confirms the tested x86 single-vCPU boot paths.
- The tiny rootfs case does not replace the full BusyBox/shell rootfs test.
- It does not claim virtio-net Firecracker, multi-vCPU, snapshot, migration, jailer, or full KVM parity.
EOF
}

finalize_checksums() {
    (
        cd "$OUT_DIR"
        find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
    )
}

need_cmd bash
need_cmd cp
need_cmd date
need_cmd find
need_cmd sha256sum
need_cmd tail
need_file "$FIRECRACKER_BIN"

mkdir -p "$OUT_DIR"
: >"$SUMMARY"

record "MATRIX_ID=$MATRIX_ID"
record "OUT_DIR=$OUT_DIR"
record "BUILD_DIR=$BUILD_DIR"
record "KVM_BUILD_DIR=$KVM_BUILD_DIR"
record "QEMU_ACCEL=$QEMU_ACCEL"
record "QEMU_CPU=${QEMU_CPU:-auto}"
record "FIRECRACKER_BIN=$FIRECRACKER_BIN"
record "NATIVE_SKIP_BUILD=$NATIVE_SKIP_BUILD"
record "KVM_INIT_SKIP_BUILD=$KVM_INIT_SKIP_BUILD"
record "FIRECRACKER_SKIP_BUILD=$FIRECRACKER_SKIP_BUILD"
record

run_case "X86-L1-ROOTFS" \
    "Layer1 x86 Linux guest boots from ext4 rootfs" \
    env BUILD_DIR="$BUILD_DIR" \
        RUN_DIR="$OUT_DIR/X86-L1-ROOTFS/run" \
        X86_GUEST_BOOT_MODE=rootfs \
        SKIP_BUILD="$NATIVE_SKIP_BUILD" \
        TIMEOUT_SECS="$TIMEOUT_SECS" \
        QEMU_ACCEL="$QEMU_ACCEL" \
        QEMU_CPU="$QEMU_CPU" \
        bash "$ROOT_DIR/tools/verify-x86-linux-host-linux-smoke.sh"
copy_if_exists "$OUT_DIR/X86-L1-ROOTFS/run/qemu.log" "$OUT_DIR/X86-L1-ROOTFS/qemu.log"
copy_if_exists "$OUT_DIR/X86-L1-ROOTFS/run/result.txt" "$OUT_DIR/X86-L1-ROOTFS/result.txt"

run_case "X86-L1-INITRAMFS" \
    "Layer1 x86 Linux guest boots from initramfs" \
    env BUILD_DIR="$BUILD_DIR" \
        RUN_DIR="$OUT_DIR/X86-L1-INITRAMFS/run" \
        X86_GUEST_BOOT_MODE=initramfs \
        SKIP_BUILD="$NATIVE_SKIP_BUILD" \
        TIMEOUT_SECS="$TIMEOUT_SECS" \
        QEMU_ACCEL="$QEMU_ACCEL" \
        QEMU_CPU="$QEMU_CPU" \
        bash "$ROOT_DIR/tools/verify-x86-linux-host-linux-smoke.sh"
copy_if_exists "$OUT_DIR/X86-L1-INITRAMFS/run/qemu.log" "$OUT_DIR/X86-L1-INITRAMFS/qemu.log"

run_case "X86-L2-KVM-INIT" \
    "Layer2 Firecracker-required KVM init ABI smoke" \
    env BUILD_DIR="$KVM_BUILD_DIR" \
        RUN_DIR="$OUT_DIR/X86-L2-KVM-INIT/run" \
        SKIP_BUILD="$KVM_INIT_SKIP_BUILD" \
        TIMEOUT_SECS="$TIMEOUT_SECS" \
        QEMU_ACCEL="$QEMU_ACCEL" \
        QEMU_CPU="$QEMU_CPU" \
        AXVISOR_KVM_DEV_NAME=kvm \
        bash "$ROOT_DIR/tools/verify-axvisor-kvm-x86-firecracker-init-smoke.sh"
copy_if_exists "$OUT_DIR/X86-L2-KVM-INIT/run/qemu.log" "$OUT_DIR/X86-L2-KVM-INIT/qemu.log"

run_case "X86-L2-FC-RUN" \
    "Layer2 unmodified Firecracker boots an x86 Linux initramfs guest through AxVisor /dev/kvm" \
    env BUILD_DIR="$KVM_BUILD_DIR" \
        RUN_DIR="$OUT_DIR/X86-L2-FC-RUN/run" \
        SKIP_BUILD="$FIRECRACKER_SKIP_BUILD" \
        TIMEOUT_SECS="$TIMEOUT_SECS" \
        QEMU_ACCEL="$QEMU_ACCEL" \
        QEMU_CPU="$QEMU_CPU" \
        FIRECRACKER_BIN="$FIRECRACKER_BIN" \
        bash "$ROOT_DIR/tools/verify-axvisor-kvm-x86-firecracker-run.sh"
copy_if_exists "$OUT_DIR/X86-L2-FC-RUN/run/qemu.log" "$OUT_DIR/X86-L2-FC-RUN/qemu.log"
copy_if_exists "$OUT_DIR/X86-L2-FC-RUN/run/firecracker-serial-decoded.log" "$OUT_DIR/X86-L2-FC-RUN/firecracker-serial-decoded.log"
copy_if_exists "$OUT_DIR/X86-L2-FC-RUN/run/firecracker-result.txt" "$OUT_DIR/X86-L2-FC-RUN/firecracker-result.txt"

run_case "X86-L2-FC-ROOTFS-TINY" \
    "Layer2 unmodified Firecracker boots an x86 rootfs guest and reaches static tiny init through AxVisor /dev/kvm" \
    env BUILD_DIR="$KVM_BUILD_DIR" \
        RUN_DIR="$OUT_DIR/X86-L2-FC-ROOTFS-TINY/run" \
        SKIP_BUILD="$FIRECRACKER_SKIP_BUILD" \
        TIMEOUT_SECS="$TIMEOUT_SECS" \
        QEMU_ACCEL="$QEMU_ACCEL" \
        QEMU_CPU="$QEMU_CPU" \
        FIRECRACKER_BIN="$FIRECRACKER_BIN" \
        FIRECRACKER_GUEST_BOOT_MODE=rootfs \
        FIRECRACKER_ROOTFS_INIT_KIND=tiny \
        bash "$ROOT_DIR/tools/verify-axvisor-kvm-x86-firecracker-run.sh"
copy_if_exists "$OUT_DIR/X86-L2-FC-ROOTFS-TINY/run/qemu.log" "$OUT_DIR/X86-L2-FC-ROOTFS-TINY/qemu.log"
copy_if_exists "$OUT_DIR/X86-L2-FC-ROOTFS-TINY/run/firecracker-serial-decoded.log" "$OUT_DIR/X86-L2-FC-ROOTFS-TINY/firecracker-serial-decoded.log"
copy_if_exists "$OUT_DIR/X86-L2-FC-ROOTFS-TINY/run/firecracker-result.txt" "$OUT_DIR/X86-L2-FC-ROOTFS-TINY/firecracker-result.txt"

if [[ "$STATUS" == "pass" ]]; then
    record "MATRIX_STATUS=pass"
else
    record "MATRIX_STATUS=fail"
fi

write_readme
finalize_checksums

if [[ "$STATUS" == "pass" ]]; then
    echo "[matrix] pass"
else
    echo "[matrix] fail" >&2
    exit 1
fi

echo "[matrix] output: $OUT_DIR"
