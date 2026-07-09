#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/output/axvisor-x86-l1-smp-scale-$RUN_ID}"
case "$OUT_DIR" in
    /*) ;;
    *) OUT_DIR="$ROOT_DIR/$OUT_DIR" ;;
esac

BUILD_DIR="${BUILD_DIR:-/tmp/axvisor-x86-smp-scale-build}"
SMP_SCALE_CPUS="${SMP_SCALE_CPUS:-1 2 4 8}"
QEMU_ACCEL="${QEMU_ACCEL:-kvm}"
QEMU_CPU="${QEMU_CPU:-}"
QEMU_MEM="${QEMU_MEM:-1536M}"
TIMEOUT_SECS="${TIMEOUT_SECS:-360}"
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
    ! grep -Eq "Kernel panic|panic:|panicked at|Oops:|BUG:|AXVISOR_X86_NATIVE_RUN_FAIL=|vcpus::exit_reason mmio_(read|write)_unhandled|emu_device .* failed" "$path"
}

validate_rootfs_scale_case() {
    local case_dir="$1"
    local cpus="$2"
    local qemu_smp="$3"
    local qemu_log="$case_dir/qemu.log"
    local result_txt="$case_dir/result.txt"
    local vm_config="$case_dir/x86_64-linux-host-vm.generated.toml"

    file_has "$vm_config" "^cpu_num = $cpus$" || return 1
    file_has "$result_txt" "^AXVISOR_X86_NATIVE_GUEST_PASS=1$" || return 1
    file_has "$result_txt" "^EXPECTED_GUEST_CPUS=$cpus$" || return 1
    file_has "$result_txt" "^CPUINFO_PROCESSOR_COUNT=$cpus$" || return 1
    file_has "$result_txt" "^CPU_ONLINE_COUNT=$cpus$" || return 1
    file_has "$result_txt" "^ROOT_MOUNT_FS=ext4$" || return 1
    file_has "$result_txt" "^SMOKE_WRITE_TEST=1$" || return 1
    file_has "$qemu_log" "VFS: Mounted root (ext4 filesystem)" || return 1
    file_has "$qemu_log" "AXVISOR_X86_NATIVE_GUEST_PASS=1" || return 1
    file_lacks_crash_markers "$qemu_log" || return 1
    grep -Fq "[verify] qemu smp: $qemu_smp" "$case_dir/run.out" || return 1
}

run_scale_case() {
    local cpus="$1"
    local case_id="L1-SMP-SCALE-$cpus"
    local case_dir="$OUT_DIR/$case_id"
    local run_out="$case_dir/run.out"
    local qemu_smp="$cpus"

    if [[ "$qemu_smp" -lt 2 ]]; then
        # The historical 1-vCPU native config binds to host CPU1.
        qemu_smp=2
    fi

    mkdir -p "$case_dir"
    echo "[smp-scale] run $case_id guest_cpus=$cpus qemu_smp=$qemu_smp"
    if BUILD_DIR="$BUILD_DIR" \
        RUN_DIR="$case_dir/run" \
        X86_GUEST_BOOT_MODE=rootfs \
        X86_GUEST_CPU_NUM="$cpus" \
        X86_GUEST_PHYS_CPU_IDS=auto \
        QEMU_SMP="$qemu_smp" \
        QEMU_ACCEL="$QEMU_ACCEL" \
        QEMU_CPU="$QEMU_CPU" \
        QEMU_MEM="$QEMU_MEM" \
        TIMEOUT_SECS="$TIMEOUT_SECS" \
        GUEST_ROOTFS_SIZE="$GUEST_ROOTFS_SIZE" \
        SKIP_BUILD=0 \
        bash "$ROOT_DIR/tools/verify-x86-linux-host-linux-smoke.sh" \
        >"$run_out" 2>&1; then
        copy_if_exists "$case_dir/run/qemu.log" "$case_dir/qemu.log"
        copy_if_exists "$case_dir/run/result.txt" "$case_dir/result.txt"
        copy_if_exists "$case_dir/run/x86_64-linux-host-vm.generated.toml" "$case_dir/x86_64-linux-host-vm.generated.toml"
        if validate_rootfs_scale_case "$case_dir" "$cpus" "$qemu_smp"; then
            record_case "$case_id" "pass" "x86 native Linux rootfs guest exposed $cpus online vCPU(s), mounted ext4, and completed write-test" \
                "$case_id/run.out" \
                "$case_id/qemu.log" \
                "$case_id/result.txt" \
                "$case_id/x86_64-linux-host-vm.generated.toml"
        else
            record_case "$case_id" "fail" "rootfs smoke exited successfully but SMP scale semantic validation failed for $cpus vCPU(s)" \
                "$case_id/run.out" \
                "$case_id/qemu.log" \
                "$case_id/result.txt" \
                "$case_id/x86_64-linux-host-vm.generated.toml"
            tail -n 240 "$run_out" >&2 || true
        fi
    else
        local rc=$?
        copy_if_exists "$case_dir/run/qemu.log" "$case_dir/qemu.log"
        copy_if_exists "$case_dir/run/result.txt" "$case_dir/result.txt"
        copy_if_exists "$case_dir/run/x86_64-linux-host-vm.generated.toml" "$case_dir/x86_64-linux-host-vm.generated.toml"
        record_case "$case_id" "fail" "x86 native Linux guest SMP scale case failed for $cpus vCPU(s), rc=$rc" \
            "$case_id/run.out" \
            "$case_id/qemu.log" \
            "$case_id/result.txt" \
            "$case_id/x86_64-linux-host-vm.generated.toml"
        tail -n 260 "$run_out" >&2 || true
    fi
}

write_readme() {
    cat >"$OUT_DIR/README.md" <<EOF
# x86 AxVisor Layer1 SMP Scale Evidence

Run ID: \`$RUN_ID\`

Status: \`$STATUS\`

This harness runs the x86 native rootfs verifier across:

\`$SMP_SCALE_CPUS\`

Each case validates guest CPU enumeration plus rootfs virtio-blk/ext4/write-test
completion with the requested guest vCPU count.

Primary files:

- \`summary.json\`
- \`summary.txt\`
- \`summary.csv\`
- per-case \`run.out\`, \`qemu.log\`, \`result.txt\`, and generated TOML
- \`SHA256SUMS\`
EOF
}

finalize_summary() {
    python3 - "$SUMMARY_JSON" "$TESTS_JSONL" "$RUN_ID" "$STATUS" "$SMP_SCALE_CPUS" <<'PY'
import json
import sys
from pathlib import Path

tests = []
tests_jsonl = Path(sys.argv[2])
if tests_jsonl.exists():
    for line in tests_jsonl.read_text().splitlines():
        if line.strip():
            tests.append(json.loads(line))
counts = {"pass": 0, "fail": 0, "skip": 0}
for test in tests:
    status = test.get("status")
    if status in counts:
        counts[status] += 1
Path(sys.argv[1]).write_text(json.dumps({
    "suite": "axvisor-x86-l1-smp-scale",
    "run_id": sys.argv[3],
    "status": sys.argv[4],
    "cpu_set": sys.argv[5].split(),
    "counts": counts,
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
need_cmd python3
need_cmd sha256sum

mkdir -p "$OUT_DIR"
: >"$SUMMARY_TXT"
printf 'id,status,reason,artifacts\n' >"$SUMMARY_CSV"
: >"$TESTS_JSONL"

for cpus in $SMP_SCALE_CPUS; do
    run_scale_case "$cpus"
done

write_readme
finalize_summary
finalize_checksums

echo "SMP_SCALE_STATUS=$STATUS"
echo "OUT_DIR=$OUT_DIR"
exit $([[ "$STATUS" == "pass" ]] && echo 0 || echo 1)
