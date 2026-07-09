#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/output/axvisor-x86-l1-mem-sizes-$RUN_ID}"
case "$OUT_DIR" in
    /*) ;;
    *) OUT_DIR="$ROOT_DIR/$OUT_DIR" ;;
esac
BUILD_DIR="${BUILD_DIR:-/tmp/axvisor-x86-mem-sizes-build}"
MEM_SIZES="${MEM_SIZES:-128M 256M 512M 1G}"
MAX_PRACTICAL_SIZE="${MAX_PRACTICAL_SIZE:-}"
TIMEOUT_SECS="${TIMEOUT_SECS:-240}"
QEMU_ACCEL="${QEMU_ACCEL:-kvm}"
QEMU_CPU="${QEMU_CPU:-}"
QEMU_MEM="${QEMU_MEM:-2304M}"

SUMMARY_TXT="$OUT_DIR/summary.txt"
SUMMARY_CSV="$OUT_DIR/summary.csv"
SUMMARY_JSON="$OUT_DIR/summary.json"
TESTS_JSONL="$OUT_DIR/.tests.jsonl"
STATUS="pass"

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "missing command: $1" >&2
        exit 1
    }
}

json_string() {
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

size_to_hex() {
    python3 - "$1" <<'PY'
import sys

value = sys.argv[1].strip().replace("_", "")
multipliers = {
    "KB": 1024,
    "MB": 1024 * 1024,
    "GB": 1024 * 1024 * 1024,
    "K": 1024,
    "M": 1024 * 1024,
    "G": 1024 * 1024 * 1024,
}
upper = value.upper()
for suffix in sorted(multipliers, key=len, reverse=True):
    if upper.endswith(suffix):
        print(f"0x{int(upper[:-len(suffix)], 0) * multipliers[suffix]:08x}")
        raise SystemExit(0)
print(f"0x{int(value, 0):08x}")
PY
}

case_name_for_size() {
    printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-//; s/-$//'
}

mark_status() {
    local test_status="$1"

    if [[ "$test_status" == "fail" ]]; then
        STATUS="fail"
    fi
}

record_case() {
    local id="$1"
    local test_status="$2"
    local reason="$3"
    shift 3

    local artifacts_json
    artifacts_json="$(python3 - "$@" <<'PY'
import json
import sys
print(json.dumps(list(sys.argv[1:])))
PY
)"
    printf '%s\n' "CASE=$id" >>"$SUMMARY_TXT"
    printf '%s\n' "STATUS=$test_status" >>"$SUMMARY_TXT"
    printf '%s\n' "REASON=$reason" >>"$SUMMARY_TXT"
    printf '%s\n\n' "ARTIFACTS=$artifacts_json" >>"$SUMMARY_TXT"
    printf '%s,%s,%s,%s\n' "$id" "$test_status" "$(printf '%s' "$reason" | tr ',' ';')" "$(printf '%s' "$artifacts_json" | tr ',' ';')" >>"$SUMMARY_CSV"
    printf '{"id":%s,"status":%s,"reason":%s,"artifacts":%s}\n' \
        "$(json_string "$id")" \
        "$(json_string "$test_status")" \
        "$(json_string "$reason")" \
        "$artifacts_json" >>"$TESTS_JSONL"
    mark_status "$test_status"
}

copy_if_exists() {
    local src="$1"
    local dst="$2"

    if [[ -e "$src" ]]; then
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst"
    fi
}

file_has() {
    local path="$1"
    local pattern="$2"

    [[ -f "$path" ]] && grep -q "$pattern" "$path"
}

file_lacks_crash_markers() {
    local path="$1"

    [[ -f "$path" ]] || return 1
    ! grep -Eq "Kernel panic|Oops:|BUG:|Call Trace:|AXVISOR_X86_NATIVE_RUN_FAIL=" "$path"
}

validate_case() {
    local size="$1"
    local case_dir="$2"
    local expected_hex="$3"
    local qemu_log="$case_dir/qemu.log"
    local result_txt="$case_dir/result.txt"
    local vm_config="$case_dir/x86_64-linux-host-vm.generated.toml"

    file_has "$vm_config" "$expected_hex" || return 1
    file_has "$result_txt" "^AXVISOR_X86_NATIVE_GUEST_PASS=1$" || return 1
    file_has "$result_txt" "^ROOT_MOUNT_FS=ext4$" || return 1
    file_has "$result_txt" "^SMOKE_WRITE_TEST=1$" || return 1
    file_has "$qemu_log" "VFS: Mounted root (ext4 filesystem)" || return 1
    file_has "$qemu_log" "AXVISOR_X86_NATIVE_GUEST_PASS=1" || return 1
    file_lacks_crash_markers "$qemu_log" || return 1
    grep -Fq "memmap=${size}\$0x40000000" "$case_dir/run.out" || return 1
}

run_size_case() {
    local size="$1"
    local case_id case_dir run_dir run_out expected_hex

    case_id="L1-MEM-$(case_name_for_size "$size")"
    case_dir="$OUT_DIR/$case_id"
    run_dir="$case_dir/run"
    run_out="$case_dir/run.out"
    expected_hex="$(size_to_hex "$size")"
    mkdir -p "$case_dir"

    echo "[mem-sizes] run $case_id size=$size expected=$expected_hex"
    if BUILD_DIR="$BUILD_DIR" \
        RUN_DIR="$run_dir" \
        X86_GUEST_BOOT_MODE=rootfs \
        X86_GUEST_IDENTITY_RAM_SIZE="$size" \
        SKIP_BUILD=0 \
        TIMEOUT_SECS="$TIMEOUT_SECS" \
        QEMU_ACCEL="$QEMU_ACCEL" \
        QEMU_CPU="$QEMU_CPU" \
        QEMU_MEM="$QEMU_MEM" \
        bash "$ROOT_DIR/tools/verify-x86-linux-host-linux-smoke.sh" \
        >"$run_out" 2>&1; then
        copy_if_exists "$run_dir/qemu.log" "$case_dir/qemu.log"
        copy_if_exists "$run_dir/result.txt" "$case_dir/result.txt"
        copy_if_exists "$run_dir/x86_64-linux-host-vm.generated.toml" "$case_dir/x86_64-linux-host-vm.generated.toml"
        copy_if_exists "$run_dir/guest-rootfs.img" "$case_dir/guest-rootfs.img"
        if validate_case "$size" "$case_dir" "$expected_hex"; then
            record_case "$case_id" "pass" "x86 native Linux guest passed with identity guest RAM size $size" \
                "$case_id/run.out" \
                "$case_id/qemu.log" \
                "$case_id/result.txt" \
                "$case_id/x86_64-linux-host-vm.generated.toml"
        else
            record_case "$case_id" "fail" "smoke script exited successfully but preserved artifacts failed semantic validation" \
                "$case_id/run.out" \
                "$case_id/qemu.log" \
                "$case_id/result.txt" \
                "$case_id/x86_64-linux-host-vm.generated.toml"
            tail -n 180 "$run_out" >&2 || true
        fi
    else
        local rc=$?
        copy_if_exists "$run_dir/qemu.log" "$case_dir/qemu.log"
        copy_if_exists "$run_dir/result.txt" "$case_dir/result.txt"
        copy_if_exists "$run_dir/x86_64-linux-host-vm.generated.toml" "$case_dir/x86_64-linux-host-vm.generated.toml"
        record_case "$case_id" "fail" "x86 native Linux guest memory-size smoke failed rc=$rc" \
            "$case_id/run.out" \
            "$case_id/qemu.log" \
            "$case_id/result.txt" \
            "$case_id/x86_64-linux-host-vm.generated.toml"
        tail -n 220 "$run_out" >&2 || true
    fi
}

write_readme() {
    cat >"$OUT_DIR/README.md" <<EOF
# x86 AxVisor Layer1 Memory Size Evidence

Run ID: \`$RUN_ID\`

Status: \`$STATUS\`

This harness validates that the Linux-host AxVisor adapter can boot an x86
Linux rootfs guest with multiple identity-mapped guest RAM sizes.

Each case forces \`SKIP_BUILD=0\` because the generated VM TOML is embedded in
\`axvisor_adapter.ko\`. Reusing a module built for a different memory size would
produce invalid evidence.

Validated condition per size:

- generated TOML contains the expected identity memory-region size.
- host kernel command line reserves the same range with \`memmap=SIZE\$0x40000000\`.
- guest reaches \`AXVISOR_X86_NATIVE_GUEST_PASS=1\`.
- guest mounts ext4 rootfs and passes the write test.
- qemu log has no panic/Oops/BUG/failure marker.

Configured sizes: \`$MEM_SIZES${MAX_PRACTICAL_SIZE:+ $MAX_PRACTICAL_SIZE}\`

Primary files:

- \`summary.txt\`
- \`summary.csv\`
- \`summary.json\`
- per-case \`run.out\`, \`qemu.log\`, \`result.txt\`, and generated TOML
- \`SHA256SUMS\`
EOF
}

finalize_summary() {
    python3 - "$SUMMARY_JSON" "$TESTS_JSONL" "$RUN_ID" "$STATUS" <<'PY'
import json
import sys
from pathlib import Path

summary = Path(sys.argv[1])
tests_jsonl = Path(sys.argv[2])
tests = []
if tests_jsonl.exists():
    for line in tests_jsonl.read_text().splitlines():
        if line.strip():
            tests.append(json.loads(line))
summary.write_text(json.dumps({
    "suite": "axvisor-x86-l1-mem-sizes",
    "run_id": sys.argv[3],
    "status": sys.argv[4],
    "tests": tests,
}, indent=2) + "\n")
PY
}

finalize_checksums() {
    (
        cd "$OUT_DIR"
        find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
        sha256sum -c SHA256SUMS >/dev/null
    )
}

need_cmd bash
need_cmd cp
need_cmd date
need_cmd find
need_cmd grep
need_cmd python3
need_cmd sha256sum
need_cmd tail

mkdir -p "$OUT_DIR"
: >"$SUMMARY_TXT"
printf 'id,status,reason,artifacts\n' >"$SUMMARY_CSV"
: >"$TESTS_JSONL"

{
    echo "RUN_ID=$RUN_ID"
    echo "OUT_DIR=$OUT_DIR"
    echo "BUILD_DIR=$BUILD_DIR"
    echo "MEM_SIZES=$MEM_SIZES"
    echo "MAX_PRACTICAL_SIZE=$MAX_PRACTICAL_SIZE"
    echo "TIMEOUT_SECS=$TIMEOUT_SECS"
    echo "QEMU_ACCEL=$QEMU_ACCEL"
    echo "QEMU_CPU=${QEMU_CPU:-auto}"
    echo "QEMU_MEM=$QEMU_MEM"
    echo
} >>"$SUMMARY_TXT"

ALL_SIZES="$MEM_SIZES"
if [[ -n "$MAX_PRACTICAL_SIZE" ]]; then
    ALL_SIZES="$ALL_SIZES $MAX_PRACTICAL_SIZE"
fi

for size in $ALL_SIZES; do
    run_size_case "$size"
done

if [[ "$STATUS" == "pass" ]]; then
    echo "MEM_SIZES_STATUS=pass" >>"$SUMMARY_TXT"
else
    echo "MEM_SIZES_STATUS=fail" >>"$SUMMARY_TXT"
fi

write_readme
finalize_summary
finalize_checksums

echo "[mem-sizes] status: $STATUS"
echo "[mem-sizes] output: $OUT_DIR"
if [[ "$STATUS" != "pass" ]]; then
    exit 1
fi
