#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/output/axvisor-x86-l1-poweroff-$RUN_ID}"
case "$OUT_DIR" in
    /*) ;;
    *) OUT_DIR="$ROOT_DIR/$OUT_DIR" ;;
esac

BUILD_DIR="${BUILD_DIR:-/tmp/axvisor-adapter-x86-build}"
QEMU_ACCEL="${QEMU_ACCEL:-kvm}"
QEMU_MEM="${QEMU_MEM:-1536M}"
QEMU_SMP="${QEMU_SMP:-1}"
X86_GUEST_CPU_NUM="${X86_GUEST_CPU_NUM:-1}"
TIMEOUT_SECS="${TIMEOUT_SECS:-240}"
GUEST_ROOTFS_SIZE="${GUEST_ROOTFS_SIZE:-64M}"

CASE_ID="L1-POWEROFF"
CASE_DIR="$OUT_DIR/$CASE_ID"
RUN_DIR="$CASE_DIR/run"
RUN_OUT="$CASE_DIR/run.out"
SUMMARY_TXT="$OUT_DIR/summary.txt"
SUMMARY_CSV="$OUT_DIR/summary.csv"
SUMMARY_JSON="$OUT_DIR/summary.json"
TESTS_JSONL="$OUT_DIR/.tests.jsonl"
STATUS="pass"

json_string() {
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

mark_status() {
    if [[ "$1" == "fail" ]]; then
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

validate_poweroff_case() {
    local qemu_log="$CASE_DIR/qemu.log"
    local result_txt="$CASE_DIR/result.txt"

    file_has "$qemu_log" "AXVISOR_X86_NATIVE_GUEST_PASS=1" || return 1
    file_has "$qemu_log" "AXVISOR_X86_NATIVE_GUEST_STAGE=after-sync" || return 1
    file_has "$qemu_log" "AXVISOR_X86_NATIVE_GUEST_STAGE=before-exit-port" || return 1
    file_has "$qemu_log" "vcpus::exit_reason system_down" || return 1
    file_has "$qemu_log" "kthread main entry returned" || return 1
    file_lacks_crash_markers "$qemu_log" || return 1
    file_has "$result_txt" "^AXVISOR_X86_NATIVE_GUEST_PASS=1$" || return 1
    file_has "$result_txt" "^ROOT_MOUNT_FS=ext4$" || return 1
    file_has "$result_txt" "^SMOKE_WRITE_TEST=1$" || return 1
    grep -Fq "[verify] pass" "$RUN_OUT" || return 1
}

write_readme() {
    cat >"$OUT_DIR/README.md" <<EOF
# x86 AxVisor L1 Poweroff Evidence

Run ID: \`$RUN_ID\`

Status: \`$STATUS\`

This harness validates \`L1-POWEROFF\`: a Linux/x86 host runs AxVisor, AxVisor
boots a Linux rootfs guest, the guest writes its deterministic result, executes
\`sync\`, emits the final PASS marker, then performs guest-triggered poweroff.

The verifier is configured with \`WAIT_FOR_POWEROFF_AFTER_PASS=1\`,
\`X86_GUEST_EXIT_PORT_AFTER_PASS=1\`, and
\`WAIT_FOR_SYSTEM_DOWN_AFTER_PASS=1\`, and
\`X86_GUEST_EXIT_PORT_AFTER_PASS=1\`, so QEMU is not killed immediately after
the PASS marker. The guest writes AxVisor's x86 test exit port, AxVisor reports
\`SystemDown\`, and the vCPU task returns. The harness then cleans up the outer
QEMU. This proves AxVisor's guest-triggered VM shutdown path; it does not claim
ACPI poweroff emulation.
EOF
}

finalize_summary() {
    python3 - "$SUMMARY_JSON" "$TESTS_JSONL" "$STATUS" <<'PY'
import json
import sys
from pathlib import Path

tests = []
path = Path(sys.argv[2])
if path.exists():
    for line in path.read_text().splitlines():
        if line.strip():
            tests.append(json.loads(line))
Path(sys.argv[1]).write_text(json.dumps({
    "suite": "axvisor-x86-l1-poweroff",
    "status": sys.argv[3],
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

mkdir -p "$CASE_DIR"
: >"$SUMMARY_TXT"
printf 'id,status,reason,artifacts\n' >"$SUMMARY_CSV"
: >"$TESTS_JSONL"

echo "[poweroff] run $CASE_ID guest_cpus=$X86_GUEST_CPU_NUM qemu_smp=$QEMU_SMP"
if BUILD_DIR="$BUILD_DIR" \
    RUN_DIR="$RUN_DIR" \
    X86_GUEST_BOOT_MODE=rootfs \
    X86_GUEST_CPU_NUM="$X86_GUEST_CPU_NUM" \
    QEMU_SMP="$QEMU_SMP" \
    QEMU_ACCEL="$QEMU_ACCEL" \
    QEMU_MEM="$QEMU_MEM" \
    GUEST_ROOTFS_SIZE="$GUEST_ROOTFS_SIZE" \
    WAIT_FOR_POWEROFF_AFTER_PASS=1 \
    WAIT_FOR_SYSTEM_DOWN_AFTER_PASS=1 \
    X86_GUEST_EXIT_PORT_AFTER_PASS=1 \
    TIMEOUT_SECS="$TIMEOUT_SECS" \
    bash "$ROOT_DIR/tools/verify-x86-linux-host-linux-smoke.sh" \
    >"$RUN_OUT" 2>&1; then
    copy_if_exists "$RUN_DIR/qemu.log" "$CASE_DIR/qemu.log"
    copy_if_exists "$RUN_DIR/result.txt" "$CASE_DIR/result.txt"
    copy_if_exists "$RUN_DIR/x86_64-linux-host-vm.generated.toml" "$CASE_DIR/x86_64-linux-host-vm.generated.toml"
    if validate_poweroff_case; then
        record_case "$CASE_ID" "pass" "guest-triggered AxVisor SystemDown stopped the VM after rootfs PASS" \
            "$CASE_ID/run.out" \
            "$CASE_ID/qemu.log" \
            "$CASE_ID/result.txt" \
            "$CASE_ID/x86_64-linux-host-vm.generated.toml"
    else
        record_case "$CASE_ID" "fail" "poweroff smoke exited successfully but semantic validation failed" \
            "$CASE_ID/run.out" \
            "$CASE_ID/qemu.log" \
            "$CASE_ID/result.txt" \
            "$CASE_ID/x86_64-linux-host-vm.generated.toml"
        tail -n 240 "$RUN_OUT" >&2 || true
    fi
else
    rc=$?
    copy_if_exists "$RUN_DIR/qemu.log" "$CASE_DIR/qemu.log"
    copy_if_exists "$RUN_DIR/result.txt" "$CASE_DIR/result.txt"
    copy_if_exists "$RUN_DIR/x86_64-linux-host-vm.generated.toml" "$CASE_DIR/x86_64-linux-host-vm.generated.toml"
    record_case "$CASE_ID" "fail" "x86 native Linux guest poweroff smoke failed rc=$rc" \
        "$CASE_ID/run.out" \
        "$CASE_ID/qemu.log" \
        "$CASE_ID/result.txt" \
        "$CASE_ID/x86_64-linux-host-vm.generated.toml"
    tail -n 260 "$RUN_OUT" >&2 || true
fi

write_readme
finalize_summary
finalize_checksums

echo "POWEROFF_STATUS=$STATUS" >>"$SUMMARY_TXT"
echo "OUT_DIR=$OUT_DIR" >>"$SUMMARY_TXT"
echo "POWEROFF_STATUS=$STATUS"
echo "OUT_DIR=$OUT_DIR"

if [[ "$STATUS" != "pass" ]]; then
    exit 1
fi
