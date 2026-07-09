#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/output/axvisor-x86-l1-functional-$RUN_ID}"
case "$OUT_DIR" in
    /*) ;;
    *) OUT_DIR="$ROOT_DIR/$OUT_DIR" ;;
esac

BUILD_DIR="${BUILD_DIR:-/tmp/axvisor-x86-functional-build}"
QEMU_ACCEL="${QEMU_ACCEL:-kvm}"
QEMU_CPU="${QEMU_CPU:-}"
QEMU_MEM="${QEMU_MEM:-1536M}"
QEMU_SMP="${QEMU_SMP:-2}"
TIMEOUT_SECS="${TIMEOUT_SECS:-360}"
GUEST_ROOTFS_SIZE="${GUEST_ROOTFS_SIZE:-64M}"
SKIP_BUILD="${SKIP_BUILD:-0}"

CASE_DIR="$OUT_DIR/L1-FUNCTIONAL"
RUN_DIR="$CASE_DIR/run"
RUN_OUT="$CASE_DIR/run.out"
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

    [[ -f "$path" ]] && grep -Eq "$pattern" "$path"
}

file_has_any() {
    local path="$1"
    shift

    local pattern
    [[ -f "$path" ]] || return 1
    for pattern in "$@"; do
        if grep -Eq "$pattern" "$path"; then
            return 0
        fi
    done
    return 1
}

file_lacks_crash_markers() {
    local path="$1"

    [[ -f "$path" ]] || return 1
    ! grep -Eq "Kernel panic|panic:|panicked at|Oops:|BUG:|AXVISOR_X86_NATIVE_RUN_FAIL=|vcpus::exit_reason mmio_(read|write)_unhandled|emu_device .* failed" "$path"
}

validate_timer() {
    local qemu_log="$CASE_DIR/qemu.log"
    local result_txt="$CASE_DIR/result.txt"

    file_has "$result_txt" "^AXVISOR_X86_NATIVE_GUEST_PASS=1$" || return 1
    file_has "$result_txt" "^TIMER_CHECK=1$" || return 1
    file_has "$result_txt" "^TIMER_MONOTONIC_OK=1$" || return 1
    file_has "$result_txt" "^TIMER_SLEEP_WAKE_OK=1$" || return 1
    file_has "$qemu_log" "x86_irq::pit_due .*count=([5-9]|[1-9][0-9])" || return 1
    file_has "$qemu_log" "x86_irq::pit_inject .*vector=0x30" || return 1
    file_lacks_crash_markers "$qemu_log" || return 1
}

validate_irq() {
    local qemu_log="$CASE_DIR/qemu.log"
    local result_txt="$CASE_DIR/result.txt"

    file_has "$result_txt" "^AXVISOR_X86_NATIVE_GUEST_PASS=1$" || return 1
    file_has "$result_txt" "^IRQ_CHECK=1$" || return 1
    file_has "$result_txt" "^IRQ_VIRTIO_DELTA_POSITIVE=1$" || return 1
    file_has_any "$qemu_log" \
        "x86 passthrough irq poll irq=19 .*pending=1" \
        "passthrough irq pending vm_id=1 irq_id=19 pending=true" || return 1
    file_has_any "$qemu_log" \
        "x86 INTx state poll-pending .*guest_gsi=19.*interrupt_pending=1" \
        "x86_irq::eoi vector=0x20 gsi=19" || return 1
    file_lacks_crash_markers "$qemu_log" || return 1
}

validate_mmio() {
    local qemu_log="$CASE_DIR/qemu.log"
    local result_txt="$CASE_DIR/result.txt"

    file_has "$result_txt" "^AXVISOR_X86_NATIVE_GUEST_PASS=1$" || return 1
    file_has "$result_txt" "^MMIO_CHECK=1$" || return 1
    file_has "$result_txt" "^MMIO_VIRTIO_RW_ITERATIONS=8$" || return 1
    file_has "$result_txt" "^MMIO_VIRTIO_RW_OK=1$" || return 1
    file_has "$qemu_log" "virtio_blk virtio0: \\[vda\\]" || return 1
    file_lacks_crash_markers "$qemu_log" || return 1
}

write_readme() {
    cat >"$OUT_DIR/README.md" <<EOF
# x86 AxVisor Layer1 Timer/IRQ/MMIO Evidence

Run ID: \`$RUN_ID\`

Status: \`$STATUS\`

This harness validates three native x86 Linux-host AxVisor functional paths
using one rootfs Linux guest run:

- \`L1-TIMER\`: guest uptime is monotonic across sleep/wakeup and AxVisor logs
  repeated PIT injections.
- \`L1-IRQ\`: guest virtio interrupt count increases while AxVisor/Linux glue
  observes pending virtio-blk INTx delivery.
- \`L1-MMIO\`: repeated virtio-blk I/O completes without unhandled MMIO/device
  faults.

Primary files:

- \`summary.json\`
- \`summary.txt\`
- \`L1-FUNCTIONAL/run.out\`
- \`L1-FUNCTIONAL/qemu.log\`
- \`L1-FUNCTIONAL/result.txt\`
- \`L1-FUNCTIONAL/x86_64-linux-host-vm.generated.toml\`
EOF
}

write_summary_json() {
    python3 - "$TESTS_JSONL" "$SUMMARY_JSON" "$STATUS" <<'PY'
import json
import sys

tests = []
for line in open(sys.argv[1], encoding="utf-8"):
    if line.strip():
        tests.append(json.loads(line))
counts = {"pass": 0, "fail": 0, "skip": 0}
for test in tests:
    status = test.get("status")
    if status in counts:
        counts[status] += 1
summary = {
    "suite": "axvisor-x86-l1-functional",
    "status": sys.argv[3],
    "counts": counts,
    "tests": tests,
}
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps(summary, indent=2) + "\n")
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
need_cmd find
need_cmd grep
need_cmd python3
need_cmd sha256sum

mkdir -p "$CASE_DIR"
: >"$SUMMARY_TXT"
printf 'id,status,reason,artifacts\n' >"$SUMMARY_CSV"
: >"$TESTS_JSONL"

echo "[functional] run L1-TIMER/L1-IRQ/L1-MMIO"
if BUILD_DIR="$BUILD_DIR" \
    RUN_DIR="$RUN_DIR" \
    X86_GUEST_BOOT_MODE=rootfs \
    X86_GUEST_EXTRA_CHECKS=timer,irq,mmio \
    QEMU_ACCEL="$QEMU_ACCEL" \
    QEMU_CPU="$QEMU_CPU" \
    QEMU_MEM="$QEMU_MEM" \
    QEMU_SMP="$QEMU_SMP" \
    X86_GUEST_CPU_NUM=1 \
    GUEST_ROOTFS_SIZE="$GUEST_ROOTFS_SIZE" \
    SKIP_BUILD="$SKIP_BUILD" \
    TIMEOUT_SECS="$TIMEOUT_SECS" \
    bash "$ROOT_DIR/tools/verify-x86-linux-host-linux-smoke.sh" \
    >"$RUN_OUT" 2>&1; then
    copy_if_exists "$RUN_DIR/qemu.log" "$CASE_DIR/qemu.log"
    copy_if_exists "$RUN_DIR/result.txt" "$CASE_DIR/result.txt"
    copy_if_exists "$RUN_DIR/x86_64-linux-host-vm.generated.toml" "$CASE_DIR/x86_64-linux-host-vm.generated.toml"
    copy_if_exists "$RUN_DIR/guest-rootfs.img" "$CASE_DIR/guest-rootfs.img"
else
    rc=$?
    copy_if_exists "$RUN_DIR/qemu.log" "$CASE_DIR/qemu.log"
    copy_if_exists "$RUN_DIR/result.txt" "$CASE_DIR/result.txt"
    copy_if_exists "$RUN_DIR/x86_64-linux-host-vm.generated.toml" "$CASE_DIR/x86_64-linux-host-vm.generated.toml"
    record_case "L1-TIMER" "fail" "functional smoke failed before timer validation rc=$rc" \
        "L1-FUNCTIONAL/run.out" "L1-FUNCTIONAL/qemu.log" "L1-FUNCTIONAL/result.txt"
    record_case "L1-IRQ" "fail" "functional smoke failed before irq validation rc=$rc" \
        "L1-FUNCTIONAL/run.out" "L1-FUNCTIONAL/qemu.log" "L1-FUNCTIONAL/result.txt"
    record_case "L1-MMIO" "fail" "functional smoke failed before mmio validation rc=$rc" \
        "L1-FUNCTIONAL/run.out" "L1-FUNCTIONAL/qemu.log" "L1-FUNCTIONAL/result.txt"
    tail -n 260 "$RUN_OUT" >&2 || true
    write_readme
    write_summary_json
    finalize_checksums
    exit 1
fi

if validate_timer; then
    record_case "L1-TIMER" "pass" "guest monotonic sleep/wakeup and repeated AxVisor PIT injection validated" \
        "L1-FUNCTIONAL/run.out" "L1-FUNCTIONAL/qemu.log" "L1-FUNCTIONAL/result.txt"
else
    record_case "L1-TIMER" "fail" "timer semantic validation failed" \
        "L1-FUNCTIONAL/run.out" "L1-FUNCTIONAL/qemu.log" "L1-FUNCTIONAL/result.txt"
fi

if validate_irq; then
    record_case "L1-IRQ" "pass" "virtio-blk interrupt count increased and INTx pending delivery was observed" \
        "L1-FUNCTIONAL/run.out" "L1-FUNCTIONAL/qemu.log" "L1-FUNCTIONAL/result.txt"
else
    record_case "L1-IRQ" "fail" "interrupt semantic validation failed" \
        "L1-FUNCTIONAL/run.out" "L1-FUNCTIONAL/qemu.log" "L1-FUNCTIONAL/result.txt"
fi

if validate_mmio; then
    record_case "L1-MMIO" "pass" "repeated virtio-blk I/O completed without unhandled MMIO/device fault" \
        "L1-FUNCTIONAL/run.out" "L1-FUNCTIONAL/qemu.log" "L1-FUNCTIONAL/result.txt"
else
    record_case "L1-MMIO" "fail" "MMIO/virtio I/O semantic validation failed" \
        "L1-FUNCTIONAL/run.out" "L1-FUNCTIONAL/qemu.log" "L1-FUNCTIONAL/result.txt"
fi

if [[ "$STATUS" == "pass" ]]; then
    echo "FUNCTIONAL_STATUS=pass" >>"$SUMMARY_TXT"
else
    echo "FUNCTIONAL_STATUS=fail" >>"$SUMMARY_TXT"
fi

write_readme
write_summary_json
finalize_checksums

if [[ "$STATUS" != "pass" ]]; then
    tail -n 260 "$RUN_OUT" >&2 || true
    exit 1
fi

echo "[functional] pass"
echo "[functional] output: $OUT_DIR"
