#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/output/axvisor-x86-l1-smp-$RUN_ID}"
case "$OUT_DIR" in
    /*) ;;
    *) OUT_DIR="$ROOT_DIR/$OUT_DIR" ;;
esac

BUILD_DIR="${BUILD_DIR:-/tmp/axvisor-x86-smp-build}"
X86_GUEST_CPU_NUM="${X86_GUEST_CPU_NUM:-2}"
X86_GUEST_PHYS_CPU_IDS="${X86_GUEST_PHYS_CPU_IDS:-auto}"
QEMU_SMP="${QEMU_SMP:-$X86_GUEST_CPU_NUM}"
QEMU_MEM="${QEMU_MEM:-1536M}"
QEMU_ACCEL="${QEMU_ACCEL:-kvm}"
QEMU_CPU="${QEMU_CPU:-}"
TIMEOUT_SECS="${TIMEOUT_SECS:-300}"
GUEST_ROOTFS_SIZE="${GUEST_ROOTFS_SIZE:-64M}"

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
    ! grep -Eq "Kernel panic|Oops:|BUG:|AXVISOR_X86_NATIVE_RUN_FAIL=" "$path"
}

validate_smp_case() {
    local case_dir="$1"
    local qemu_log="$case_dir/qemu.log"
    local result_txt="$case_dir/result.txt"
    local vm_config="$case_dir/x86_64-linux-host-vm.generated.toml"

    file_has "$vm_config" "^cpu_num = $X86_GUEST_CPU_NUM$" || return 1
    file_has "$result_txt" "^AXVISOR_X86_NATIVE_GUEST_PASS=1$" || return 1
    file_has "$result_txt" "^EXPECTED_GUEST_CPUS=$X86_GUEST_CPU_NUM$" || return 1
    file_has "$result_txt" "^CPUINFO_PROCESSOR_COUNT=$X86_GUEST_CPU_NUM$" || return 1
    file_has "$result_txt" "^CPU_ONLINE_COUNT=$X86_GUEST_CPU_NUM$" || return 1
    file_has "$result_txt" "^ROOT_MOUNT_FS=ext4$" || return 1
    file_has "$result_txt" "^SMOKE_WRITE_TEST=1$" || return 1
    file_has "$qemu_log" "VFS: Mounted root (ext4 filesystem)" || return 1
    file_has "$qemu_log" "AXVISOR_X86_NATIVE_GUEST_PASS=1" || return 1
    file_lacks_crash_markers "$qemu_log" || return 1
    grep -Fq "[verify] qemu smp: $QEMU_SMP" "$case_dir/run.out" || return 1
}

validate_smp_boot_case() {
    local case_dir="$1"
    local qemu_log="$case_dir/qemu.log"
    local vm_config="$case_dir/x86_64-linux-host-vm.generated.toml"

    file_has "$vm_config" "^cpu_num = $X86_GUEST_CPU_NUM$" || return 1
    file_has "$qemu_log" "smp: Brought up 1 node, $X86_GUEST_CPU_NUM CPUs" || return 1
    file_has "$qemu_log" "AXVISOR_X86_NATIVE_GUEST_EXPECTED_CPUS=$X86_GUEST_CPU_NUM" || return 1
    file_has "$qemu_log" "AXVISOR_X86_NATIVE_GUEST_CPUINFO_PROCESSOR_COUNT=$X86_GUEST_CPU_NUM" || return 1
    file_has "$qemu_log" "AXVISOR_X86_NATIVE_GUEST_CPU_ONLINE_COUNT=$X86_GUEST_CPU_NUM" || return 1
    file_has "$qemu_log" "AXVISOR_X86_NATIVE_GUEST_PASS=1" || return 1
    file_lacks_crash_markers "$qemu_log" || return 1
    grep -Fq "[verify] qemu smp: $QEMU_SMP" "$case_dir/run.out" || return 1
}

run_smp_boot_case() {
    local case_id="L1-SMP-$X86_GUEST_CPU_NUM-BOOT"
    local case_dir="$OUT_DIR/$case_id"
    local run_dir="$case_dir/run"
    local run_out="$case_dir/run.out"

    mkdir -p "$case_dir"
    echo "[smp] run $case_id guest_cpus=$X86_GUEST_CPU_NUM qemu_smp=$QEMU_SMP boot_mode=initramfs"

    if BUILD_DIR="$BUILD_DIR" \
        RUN_DIR="$run_dir" \
        X86_GUEST_BOOT_MODE=initramfs \
        X86_GUEST_CPU_NUM="$X86_GUEST_CPU_NUM" \
        X86_GUEST_PHYS_CPU_IDS="$X86_GUEST_PHYS_CPU_IDS" \
        QEMU_SMP="$QEMU_SMP" \
        QEMU_ACCEL="$QEMU_ACCEL" \
        QEMU_CPU="$QEMU_CPU" \
        QEMU_MEM="$QEMU_MEM" \
        GUEST_ROOTFS_SIZE="$GUEST_ROOTFS_SIZE" \
        SKIP_BUILD=0 \
        TIMEOUT_SECS="$TIMEOUT_SECS" \
        bash "$ROOT_DIR/tools/verify-x86-linux-host-linux-smoke.sh" \
        >"$run_out" 2>&1; then
        copy_if_exists "$run_dir/qemu.log" "$case_dir/qemu.log"
        copy_if_exists "$run_dir/x86_64-linux-host-vm.generated.toml" "$case_dir/x86_64-linux-host-vm.generated.toml"
        if validate_smp_boot_case "$case_dir"; then
            record_case "$case_id" "pass" "x86 native Linux initramfs guest booted and reported exactly $X86_GUEST_CPU_NUM online CPUs" \
                "$case_id/run.out" \
                "$case_id/qemu.log" \
                "$case_id/x86_64-linux-host-vm.generated.toml"
        else
            record_case "$case_id" "fail" "initramfs smoke exited successfully but SMP boot validation failed" \
                "$case_id/run.out" \
                "$case_id/qemu.log" \
                "$case_id/x86_64-linux-host-vm.generated.toml"
            tail -n 220 "$run_out" >&2 || true
        fi
    else
        local rc=$?
        copy_if_exists "$run_dir/qemu.log" "$case_dir/qemu.log"
        copy_if_exists "$run_dir/x86_64-linux-host-vm.generated.toml" "$case_dir/x86_64-linux-host-vm.generated.toml"
        record_case "$case_id" "fail" "x86 native Linux guest SMP initramfs smoke failed rc=$rc" \
            "$case_id/run.out" \
            "$case_id/qemu.log" \
            "$case_id/x86_64-linux-host-vm.generated.toml"
        tail -n 260 "$run_out" >&2 || true
    fi
}

run_smp_rootfs_case() {
    local case_id="L1-SMP-$X86_GUEST_CPU_NUM"
    local case_dir="$OUT_DIR/$case_id"
    local run_dir="$case_dir/run"
    local run_out="$case_dir/run.out"

    mkdir -p "$case_dir"
    echo "[smp] run $case_id guest_cpus=$X86_GUEST_CPU_NUM qemu_smp=$QEMU_SMP boot_mode=rootfs"

    if BUILD_DIR="$BUILD_DIR" \
        RUN_DIR="$run_dir" \
        X86_GUEST_BOOT_MODE=rootfs \
        X86_GUEST_CPU_NUM="$X86_GUEST_CPU_NUM" \
        X86_GUEST_PHYS_CPU_IDS="$X86_GUEST_PHYS_CPU_IDS" \
        QEMU_SMP="$QEMU_SMP" \
        QEMU_ACCEL="$QEMU_ACCEL" \
        QEMU_CPU="$QEMU_CPU" \
        QEMU_MEM="$QEMU_MEM" \
        GUEST_ROOTFS_SIZE="$GUEST_ROOTFS_SIZE" \
        SKIP_BUILD=0 \
        TIMEOUT_SECS="$TIMEOUT_SECS" \
        bash "$ROOT_DIR/tools/verify-x86-linux-host-linux-smoke.sh" \
        >"$run_out" 2>&1; then
        copy_if_exists "$run_dir/qemu.log" "$case_dir/qemu.log"
        copy_if_exists "$run_dir/result.txt" "$case_dir/result.txt"
        copy_if_exists "$run_dir/x86_64-linux-host-vm.generated.toml" "$case_dir/x86_64-linux-host-vm.generated.toml"
        copy_if_exists "$run_dir/guest-rootfs.img" "$case_dir/guest-rootfs.img"
        if validate_smp_case "$case_dir"; then
            record_case "$case_id" "pass" "x86 native Linux rootfs guest exposed and online exactly $X86_GUEST_CPU_NUM CPUs" \
                "$case_id/run.out" \
                "$case_id/qemu.log" \
                "$case_id/result.txt" \
                "$case_id/x86_64-linux-host-vm.generated.toml"
        else
            record_case "$case_id" "fail" "rootfs smoke exited successfully but SMP semantic validation failed" \
                "$case_id/run.out" \
                "$case_id/qemu.log" \
                "$case_id/x86_64-linux-host-vm.generated.toml"
            tail -n 220 "$run_out" >&2 || true
        fi
    else
        local rc=$?
        copy_if_exists "$run_dir/qemu.log" "$case_dir/qemu.log"
        copy_if_exists "$run_dir/result.txt" "$case_dir/result.txt"
        copy_if_exists "$run_dir/x86_64-linux-host-vm.generated.toml" "$case_dir/x86_64-linux-host-vm.generated.toml"
        record_case "$case_id" "fail" "x86 native Linux guest SMP rootfs smoke failed rc=$rc" \
            "$case_id/run.out" \
            "$case_id/qemu.log" \
            "$case_id/x86_64-linux-host-vm.generated.toml"
        tail -n 260 "$run_out" >&2 || true
    fi
}

write_readme() {
    cat >"$OUT_DIR/README.md" <<EOF
# x86 AxVisor Layer1 SMP Evidence

Run ID: \`$RUN_ID\`

Status: \`$STATUS\`

This harness validates native x86 Linux-host AxVisor guest SMP behavior in two
layers:

- \`L1-SMP-$X86_GUEST_CPU_NUM-BOOT\`: initramfs guest reaches userspace and
  reports exactly \`$X86_GUEST_CPU_NUM\` processors in \`/proc/cpuinfo\` and
  exactly \`$X86_GUEST_CPU_NUM\` online CPUs from
  \`/sys/devices/system/cpu/online\`.
- \`L1-SMP-$X86_GUEST_CPU_NUM\`: rootfs guest additionally proves virtio-blk
  rootfs I/O, ext4 mount, and write-test completion under SMP.

The suite status is \`pass\` only if both layers pass.

Configuration:

- guest CPUs: \`$X86_GUEST_CPU_NUM\`
- guest phys CPU IDs: \`$X86_GUEST_PHYS_CPU_IDS\`
- QEMU host SMP: \`$QEMU_SMP\`

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
    "suite": "axvisor-x86-l1-smp",
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

mkdir -p "$OUT_DIR"
: >"$SUMMARY_TXT"
printf 'id,status,reason,artifacts\n' >"$SUMMARY_CSV"
: >"$TESTS_JSONL"

run_smp_boot_case
run_smp_rootfs_case
write_readme
finalize_summary
finalize_checksums

echo "SMP_STATUS=$STATUS"
echo "OUT_DIR=$OUT_DIR"
exit $([[ "$STATUS" == "pass" ]] && echo 0 || echo 1)
