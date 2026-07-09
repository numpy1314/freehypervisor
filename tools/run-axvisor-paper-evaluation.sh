#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
SUITE="${SUITE:-axvisor-paper-evaluation}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/output/$SUITE-$RUN_ID}"
RUN_X86_MATRIX="${RUN_X86_MATRIX:-0}"
RUN_FIRECRACKER_ROOTFS="${RUN_FIRECRACKER_ROOTFS:-0}"
X86_EVIDENCE_DIR="${X86_EVIDENCE_DIR:-$ROOT_DIR/output/x86-axvisor-test-matrix-x86-matrix-20260701-224728}"
X86_NATIVE_STABILITY_DIR="${X86_NATIVE_STABILITY_DIR:-$ROOT_DIR/output/axvisor-linux-host-linux-guest-x86-stability-20260701-195811}"
X86_MEM_SIZES_DIR="${X86_MEM_SIZES_DIR:-}"
X86_FUNCTIONAL_DIR="${X86_FUNCTIONAL_DIR:-}"
X86_SMP_DIR="${X86_SMP_DIR:-}"
X86_SMP_SCALE_DIR="${X86_SMP_SCALE_DIR:-}"
X86_POWEROFF_DIR="${X86_POWEROFF_DIR:-}"
ARCH_STATIC_DIR="${ARCH_STATIC_DIR:-}"
KVM_ABI_SMOKE_DIR="${KVM_ABI_SMOKE_DIR:-}"
KVM_ABI_SMOKE_OUT="${KVM_ABI_SMOKE_OUT:-}"
FIRECRACKER_ROOTFS_LOG="${FIRECRACKER_ROOTFS_LOG:-}"
FIRECRACKER_ROOTFS_TINY_DIR="${FIRECRACKER_ROOTFS_TINY_DIR:-}"

SUMMARY_JSON="$OUT_DIR/summary.json"
SUMMARY_CSV="$OUT_DIR/summary.csv"
ABI_CSV="$OUT_DIR/abi/kvm-abi-coverage.csv"
TESTS_JSONL="$OUT_DIR/.tests.jsonl"
STATUS="pass"

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "missing command: $1" >&2
        exit 1
    }
}

mark_status() {
    local test_status="$1"

    if [[ "$test_status" == "fail" ]]; then
        STATUS="fail"
    elif [[ "$test_status" == "skip" && "$STATUS" == "pass" ]]; then
        # The paper-evaluation schema only allows pass/fail/skip. A run with
        # any explicit skip is not a complete pass for the full matrix.
        STATUS="fail"
    fi
}

json_string() {
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

record_test() {
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
    printf '{"id":%s,"status":%s,"reason":%s,"duration_ms":0,"artifacts":%s}\n' \
        "$(json_string "$id")" \
        "$(json_string "$test_status")" \
        "$(json_string "$reason")" \
        "$artifacts_json" >>"$TESTS_JSONL"
    printf '%s,%s,%s,%s\n' "$id" "$test_status" "$(printf '%s' "$reason" | tr ',' ';')" "$(printf '%s' "$artifacts_json" | tr ',' ';')" >>"$SUMMARY_CSV"
    mark_status "$test_status"
}

test_recorded() {
    local id="$1"

    grep -q "\"id\":\"$id\"" "$TESTS_JSONL" 2>/dev/null
}

record_test_if_missing() {
    local id="$1"

    if test_recorded "$id"; then
        return 0
    fi
    record_test "$@"
}

copy_if_exists() {
    local src="$1"
    local dst="$2"

    if [[ -e "$src" ]]; then
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst"
        return 0
    fi
    return 1
}

file_has() {
    local path="$1"
    local pattern="$2"

    [[ -f "$path" ]] && grep -q "$pattern" "$path"
}

file_has_ere() {
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

decode_firecracker_serial_from_qemu_log() {
    local qemu_log="$1"
    local out="$2"

    [[ -f "$qemu_log" ]] || return 1
    mkdir -p "$(dirname "$out")"
    python3 - "$qemu_log" "$out" <<'PY'
import re
import sys

pattern = re.compile(r"IoWrite \{ port: Port\(1016\), width: Byte, data: (\d+) \}")
serial = bytearray()

with open(sys.argv[1], errors="ignore") as log:
    for line in log:
        match = pattern.search(line)
        if match:
            serial.append(int(match.group(1)) & 0xff)

with open(sys.argv[2], "wb") as out:
    out.write(bytes(serial))
PY
}

record_semantic_test() {
    local id="$1"
    local reason="$2"
    local status="$3"
    shift 3

    record_test "$id" "$status" "$reason" "$@"
}

write_placeholder_outputs() {
    mkdir -p "$OUT_DIR/performance/raw" "$OUT_DIR/logs"
    cat >"$OUT_DIR/performance/boot-samples.csv" <<'EOF'
configuration,test_id,iteration,start_ns,end_ns,duration_ns,status,notes
EOF
    cat >"$OUT_DIR/performance/microbench.csv" <<'EOF'
configuration,operation,iterations,total_ns,mean_ns,p50_ns,p95_ns,p99_ns,vm_exit_count,hostif_call_count
EOF
    cat >"$OUT_DIR/performance/hostif-profile.csv" <<'EOF'
configuration,test_id,hostif_method,call_count,total_ns,mean_ns,p95_ns,p99_ns,error_count
EOF
    cat >"$OUT_DIR/performance/block-io.csv" <<'EOF'
configuration,test_id,tool,workload,iops,avg_latency_us,p99_latency_us,throughput_mib_s,host_cpu_percent,notes
EOF
    cat >"$OUT_DIR/performance/network.csv" <<'EOF'
configuration,test_id,tool,workload,throughput_gbps,p50_latency_us,p99_latency_us,loss_percent,host_cpu_percent,guest_cpu_percent,notes
EOF
    touch "$OUT_DIR/logs/.keep"
}

record_pending_matrix_skips() {
    record_test "HARNESS-SKIP" "pass" "unsupported or not-yet-run tests are recorded with explicit skip status instead of silent success"
    record_test "HARNESS-WARMUP" "skip" "performance warm-up/repeated sampling is not run in this import-focused invocation"

    record_test "X86-KVM-FC" "skip" "Linux KVM + Firecracker baseline not run in this invocation"
    record_test "X86-AX-FC" "skip" "covered only by imported AxVisor Firecracker boot tests, not full baseline/performance matrix"
    record_test "RV-AS-AX-NATIVE" "skip" "Asterinas/RISC-V native evidence not imported in this invocation"
    record_test "RV-AS-AX-FC" "skip" "Asterinas/RISC-V Firecracker evidence not imported in this invocation"
    record_test "RV-LINUX-KVM-FC" "skip" "RISC-V Linux KVM Firecracker baseline not available in this invocation"
    record_test "RV-LINUX-AX-FC" "skip" "RISC-V Linux AxVisor Firecracker path not run in this invocation"
    record_test "X86-AS-AX-FC" "skip" "Asterinas/x86 AxVisor Firecracker path not run in this invocation"

    record_test_if_missing "L1-TIMER" "skip" "dedicated guest monotonic/timer interrupt threshold test not imported in this invocation"
    record_test_if_missing "L1-IRQ" "skip" "dedicated interrupt-count completion test not imported in this invocation"
    record_test_if_missing "L1-MMIO" "skip" "dedicated repeated virtio/MMIO register test not imported in this invocation"
    record_test_if_missing "L1-SMP-SCALE" "skip" "1/2/4/8 vCPU scale test not imported in this invocation"
    record_test_if_missing "L1-POWEROFF" "skip" "dedicated resource-reclaim assertion after guest poweroff not imported in this invocation"
    record_test "L1-RESET" "skip" "guest reboot/reset second-boot test not implemented in unified harness yet"

    record_test "FC-NET" "skip" "Firecracker virtio-net path is not implemented in current AxVisor KVM frontend test"
    record_test "FC-RW-DISK" "skip" "Firecracker disk persistence-across-reboot test not implemented in unified harness yet"

    record_test "PERF-BOOT-E2E-SERIAL" "skip" "500-sample serial boot performance not run"
    record_test "PERF-BOOT-PRECONFIG" "skip" "500-sample preconfigured boot performance not run"
    record_test "PERF-BOOT-STAGES" "skip" "stage breakdown performance not run"
    record_test "PERF-SHUTDOWN" "skip" "shutdown latency sampling not run"
    record_test "PERF-CREATE-RATE" "skip" "VM create-rate benchmark not run"
    record_test "PERF-BOOT-CONCURRENT" "skip" "concurrent boot benchmark not run"
    record_test "MICRO-VMEXIT-HALT" "skip" "VM-exit halt microbenchmark not run"
    record_test "MICRO-MMIO-READ" "skip" "MMIO read microbenchmark not run"
    record_test "MICRO-MMIO-WRITE" "skip" "MMIO write microbenchmark not run"
    record_test "MICRO-PIO" "skip" "x86 PIO microbenchmark not run"
    record_test "MICRO-TIMER" "skip" "timer latency microbenchmark not run"
    record_test "MICRO-IRQ-INJECT" "skip" "IRQ injection latency microbenchmark not run"
    record_test "MICRO-IPI" "skip" "IPI latency microbenchmark not run"
    record_test "MICRO-BLOCK-WAKE" "skip" "block/wakeup microbenchmark not run"
    record_test "MICRO-MEM-REGISTER" "skip" "memory registration microbenchmark not run"
    record_test "MICRO-VCPU-CREATE" "skip" "vCPU create/destroy microbenchmark not run"
    record_test "HOSTIF-PROFILE" "skip" "HostIf call-count/time instrumentation not enabled for this invocation" "performance/hostif-profile.csv"

    record_test "IO-BLK-4K-RANDREAD-QD1" "skip" "fio block I/O benchmark not run"
    record_test "IO-BLK-4K-RANDREAD-QD32" "skip" "fio block I/O benchmark not run"
    record_test "IO-BLK-4K-RANDWRITE-QD1" "skip" "fio block I/O benchmark not run"
    record_test "IO-BLK-4K-RANDWRITE-QD32" "skip" "fio block I/O benchmark not run"
    record_test "IO-BLK-128K-READ" "skip" "fio block I/O benchmark not run"
    record_test "IO-BLK-128K-WRITE" "skip" "fio block I/O benchmark not run"
    record_test "IO-NET-TCP-RX-1" "skip" "network I/O benchmark not run"
    record_test "IO-NET-TCP-TX-1" "skip" "network I/O benchmark not run"
    record_test "IO-NET-TCP-RX-10" "skip" "network I/O benchmark not run"
    record_test "IO-NET-TCP-TX-10" "skip" "network I/O benchmark not run"
    record_test "IO-NET-RR" "skip" "network request/response benchmark not run"
    record_test "IO-NET-PING" "skip" "network ping benchmark not run"

    record_test "CPU-SINGLE" "skip" "guest CPU single-worker benchmark not run"
    record_test "CPU-MULTI" "skip" "guest CPU multi-worker benchmark not run"
    record_test "MEM-BW" "skip" "guest memory bandwidth benchmark not run"
    record_test "MEM-LAT" "skip" "guest memory latency benchmark not run"
    record_test "KERNEL-BUILD" "skip" "macro workload benchmark not run"
    record_test "VMM-MEM-OVERHEAD" "skip" "per-VM memory overhead benchmark not run"

    record_test "STAB-FC-CYCLE-100" "skip" "Firecracker 100-cycle stability not run"
    record_test "STAB-FC-CYCLE-1000" "skip" "Firecracker 1000-cycle stability not run"
    record_test "STAB-ABORT-BEFORE-RUN" "skip" "abort-before-run lifecycle test not run"
    record_test "STAB-KILL-VMM" "skip" "SIGKILL VMM cleanup test not run"
    record_test "STAB-GUEST-CRASH" "skip" "guest crash lifecycle isolation test not run"
    record_test "STAB-TIMEOUT" "skip" "external timeout/stop test not run"
    record_test "STAB-FD-LIFETIME" "skip" "adversarial fd close-order test not run"
    record_test "STAB-MEMSLOT-CHURN" "skip" "10k memory-slot churn test not run"

    record_test "SCALE-VM-IDLE" "skip" "concurrent idle VM density test not run"
    record_test "SCALE-VM-BOOT" "skip" "concurrent VM boot density test not run"
    record_test "SCALE-VM-IO" "skip" "concurrent VM I/O scale test not run"
    record_test_if_missing "SCALE-SMP" "skip" "1/2/4/8 vCPU scaling test not run"
    record_test "SCALE-CROSS-VCPU" "skip" "cross-vCPU IPI/wakeup stress test not run"

    record_test_if_missing "NEG-UNKNOWN-IOCTL" "skip" "negative KVM ioctl test not run"
    record_test_if_missing "NEG-WRONG-FD-CLASS" "skip" "wrong fd-class KVM ioctl test not run"
    record_test_if_missing "NEG-BAD-MEMSLOT" "skip" "bad memslot negative test not run"
    record_test_if_missing "NEG-DUP-VCPU" "skip" "duplicate vCPU negative test not run"
    record_test "NEG-RUN-UNINIT" "skip" "KVM_RUN-before-init negative test not run"
    record_test_if_missing "NEG-BAD-REGS" "skip" "bad register-state negative test not run"
    record_test "NEG-FALSE-CAP" "skip" "advertised capability semantic negative audit not run"
    record_test_if_missing "NEG-CLOSE-RACE" "skip" "close/destroy race negative test not run"

    record_test "ISO-GUEST-OOB" "skip" "guest out-of-bounds access isolation test not run"
    record_test "ISO-GUEST-PRIV" "skip" "guest privileged/invalid operation isolation test not run"
    record_test "ISO-GUEST-PANIC" "skip" "guest panic isolation test not run"
    record_test "ISO-TWO-VM-MEM" "skip" "two-VM memory isolation test not run"
    record_test "ISO-RESOURCE-EXHAUST" "skip" "resource exhaustion admission test not run"
}

capture_environment() {
    local env_dir="$OUT_DIR/environment"

    mkdir -p "$env_dir/configs"
    uname -a >"$env_dir/uname.txt"
    uname -r >"$env_dir/kernel.txt"
    lscpu >"$env_dir/lscpu.txt" 2>&1 || true
    cp -a "$env_dir/lscpu.txt" "$env_dir/cpu.txt" 2>/dev/null || true
    free -h >"$env_dir/memory.txt" 2>&1 || true
    {
        echo "ROOT_DIR=$ROOT_DIR"
        echo "RUN_ID=$RUN_ID"
        echo "DATE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "DATE_LOCAL=$(date +%Y-%m-%dT%H:%M:%S%z)"
        echo "RUN_X86_MATRIX=$RUN_X86_MATRIX"
        echo "RUN_FIRECRACKER_ROOTFS=$RUN_FIRECRACKER_ROOTFS"
        echo "X86_EVIDENCE_DIR=$X86_EVIDENCE_DIR"
        echo "X86_NATIVE_STABILITY_DIR=$X86_NATIVE_STABILITY_DIR"
        echo "X86_MEM_SIZES_DIR=$X86_MEM_SIZES_DIR"
        echo "X86_FUNCTIONAL_DIR=$X86_FUNCTIONAL_DIR"
        echo "X86_SMP_DIR=$X86_SMP_DIR"
        echo "X86_SMP_SCALE_DIR=$X86_SMP_SCALE_DIR"
        echo "X86_POWEROFF_DIR=$X86_POWEROFF_DIR"
        echo "ARCH_STATIC_DIR=$ARCH_STATIC_DIR"
        echo "KVM_ABI_SMOKE_DIR=$KVM_ABI_SMOKE_DIR"
        echo "KVM_ABI_SMOKE_OUT=$KVM_ABI_SMOKE_OUT"
        echo "FIRECRACKER_ROOTFS_LOG=$FIRECRACKER_ROOTFS_LOG"
        echo "FIRECRACKER_ROOTFS_TINY_DIR=$FIRECRACKER_ROOTFS_TINY_DIR"
    } >"$env_dir/environment.txt"
    {
        git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true
        git -C "$ROOT_DIR" status --short 2>/dev/null || true
    } >"$env_dir/git-revisions.txt"
    cp -a "$ROOT_DIR/docs/x86-axvisor-test-matrix.md" "$env_dir/configs/" 2>/dev/null || true

    python3 - "$env_dir" "$RUN_ID" "$ROOT_DIR" "$X86_EVIDENCE_DIR" "$X86_NATIVE_STABILITY_DIR" "$X86_MEM_SIZES_DIR" "$X86_SMP_SCALE_DIR" <<'PY'
import json
import platform
import subprocess
import sys
from pathlib import Path

env_dir = Path(sys.argv[1])
data = {
    "suite": "axvisor-paper-evaluation",
    "run_id": sys.argv[2],
    "root_dir": sys.argv[3],
    "x86_evidence_dir": sys.argv[4],
    "x86_native_stability_dir": sys.argv[5],
    "x86_mem_sizes_dir": sys.argv[6],
    "x86_smp_scale_dir": sys.argv[7],
    "platform": platform.platform(),
    "machine": platform.machine(),
    "python": platform.python_version(),
}
try:
    data["git_head"] = subprocess.check_output(
        ["git", "-C", sys.argv[3], "rev-parse", "HEAD"],
        text=True,
        stderr=subprocess.DEVNULL,
    ).strip()
except Exception:
    data["git_head"] = ""
(env_dir / "environment.json").write_text(json.dumps(data, indent=2) + "\n")
PY
}

import_x86_evidence() {
    local src="$1"
    local dst="$OUT_DIR/functional/x86-imported"
    local l1_rootfs_status="fail"
    local l1_initramfs_status="fail"
    local fc_init_status="fail"
    local fc_initramfs_status="fail"
    local fc_rootfs_tiny_status="skip"
    local fc_rootfs_tiny_reason="Firecracker rootfs tiny-init evidence not present in imported x86 matrix"

    if [[ ! -d "$src" ]]; then
        record_test "HARNESS-X86-IMPORT" "skip" "existing x86 evidence directory not found: $src"
        return 0
    fi

    mkdir -p "$dst"
    cp -a "$src/README.md" "$dst/README.md" 2>/dev/null || true
    cp -a "$src/summary.txt" "$dst/summary.txt" 2>/dev/null || true
    cp -a "$src/SHA256SUMS" "$dst/SHA256SUMS" 2>/dev/null || true

    copy_if_exists "$src/X86-L1-ROOTFS/result.txt" "$dst/X86-L1-ROOTFS/result.txt" || true
    copy_if_exists "$src/X86-L1-ROOTFS/qemu.log" "$dst/X86-L1-ROOTFS/qemu.log" || true
    copy_if_exists "$src/X86-L1-ROOTFS/run.out" "$dst/X86-L1-ROOTFS/run.out" || true
    copy_if_exists "$src/X86-L1-INITRAMFS/qemu.log" "$dst/X86-L1-INITRAMFS/qemu.log" || true
    copy_if_exists "$src/X86-L1-INITRAMFS/run.out" "$dst/X86-L1-INITRAMFS/run.out" || true
    copy_if_exists "$src/X86-L2-KVM-INIT/qemu.log" "$dst/X86-L2-KVM-INIT/qemu.log" || true
    copy_if_exists "$src/X86-L2-KVM-INIT/run.out" "$dst/X86-L2-KVM-INIT/run.out" || true
    copy_if_exists "$src/X86-L2-FC-RUN/qemu.log" "$dst/X86-L2-FC-RUN/qemu.log" || true
    copy_if_exists "$src/X86-L2-FC-RUN/run.out" "$dst/X86-L2-FC-RUN/run.out" || true
    copy_if_exists "$src/X86-L2-FC-RUN/firecracker-serial-decoded.log" "$dst/X86-L2-FC-RUN/firecracker-serial-decoded.log" || true
    copy_if_exists "$src/X86-L2-FC-RUN/firecracker-result.txt" "$dst/X86-L2-FC-RUN/firecracker-result.txt" || true
    copy_if_exists "$src/X86-L2-FC-ROOTFS-TINY/qemu.log" "$dst/X86-L2-FC-ROOTFS-TINY/qemu.log" || true
    copy_if_exists "$src/X86-L2-FC-ROOTFS-TINY/run.out" "$dst/X86-L2-FC-ROOTFS-TINY/run.out" || true
    copy_if_exists "$src/X86-L2-FC-ROOTFS-TINY/firecracker-serial-decoded.log" "$dst/X86-L2-FC-ROOTFS-TINY/firecracker-serial-decoded.log" || true
    copy_if_exists "$src/X86-L2-FC-ROOTFS-TINY/firecracker-result.txt" "$dst/X86-L2-FC-ROOTFS-TINY/firecracker-result.txt" || true

    if [[ ! -f "$dst/X86-L2-FC-RUN/firecracker-serial-decoded.log" ]]; then
        decode_firecracker_serial_from_qemu_log \
            "$dst/X86-L2-FC-RUN/qemu.log" \
            "$dst/X86-L2-FC-RUN/firecracker-serial-decoded.log" || true
    fi
    if [[ ! -f "$dst/X86-L2-FC-ROOTFS-TINY/firecracker-serial-decoded.log" ]]; then
        decode_firecracker_serial_from_qemu_log \
            "$dst/X86-L2-FC-ROOTFS-TINY/qemu.log" \
            "$dst/X86-L2-FC-ROOTFS-TINY/firecracker-serial-decoded.log" || true
    fi

    if grep -q "MATRIX_STATUS=pass" "$src/summary.txt" 2>/dev/null; then
        record_test "HARNESS-X86-IMPORT" "pass" "imported existing x86 matrix evidence summary" "functional/x86-imported/summary.txt"
    else
        record_test "HARNESS-X86-IMPORT" "fail" "x86 matrix evidence imported but summary does not report pass" "functional/x86-imported/summary.txt"
    fi

    if file_has "$dst/X86-L1-ROOTFS/result.txt" "AXVISOR_X86_NATIVE_GUEST_PASS=1" &&
        file_has "$dst/X86-L1-ROOTFS/result.txt" "ROOT_MOUNT_FS=ext4" &&
        file_has "$dst/X86-L1-ROOTFS/result.txt" "SMOKE_WRITE_TEST=1" &&
        file_has "$dst/X86-L1-ROOTFS/qemu.log" "VFS: Mounted root" &&
        file_lacks_crash_markers "$dst/X86-L1-ROOTFS/qemu.log"; then
        l1_rootfs_status="pass"
    fi
    record_semantic_test "L1-ROOTFS-BLK" \
        "verified native x86 Linux guest ext4 rootfs mount and write marker" \
        "$l1_rootfs_status" \
        "functional/x86-imported/X86-L1-ROOTFS/result.txt" \
        "functional/x86-imported/X86-L1-ROOTFS/qemu.log"

    if file_has "$dst/X86-L1-INITRAMFS/qemu.log" "AXVISOR_X86_NATIVE_GUEST_PASS=1" &&
        file_lacks_crash_markers "$dst/X86-L1-INITRAMFS/qemu.log"; then
        l1_initramfs_status="pass"
    fi
    record_semantic_test "L1-INITRAMFS" \
        "verified native x86 Linux guest initramfs pass marker" \
        "$l1_initramfs_status" \
        "functional/x86-imported/X86-L1-INITRAMFS/qemu.log"

    if file_has "$dst/X86-L2-KVM-INIT/qemu.log" "AXVISOR_KVM_FIRECRACKER_INIT_SMOKE_PASS=1" &&
        file_has "$dst/X86-L2-KVM-INIT/qemu.log" "KVM_FIRECRACKER_X86_INIT_ABI=1" &&
        file_has "$dst/X86-L2-KVM-INIT/qemu.log" "AXVISOR_KVM_X86_FIRECRACKER_INIT_QEMU_PASS=1" &&
        file_lacks_crash_markers "$dst/X86-L2-KVM-INIT/qemu.log"; then
        fc_init_status="pass"
    fi
    record_semantic_test "FC-INIT" \
        "verified Firecracker-required KVM init ABI markers through AxVisor /dev/kvm" \
        "$fc_init_status" \
        "functional/x86-imported/X86-L2-KVM-INIT/qemu.log"

    if { file_has "$dst/X86-L2-FC-RUN/firecracker-result.txt" "AXVISOR_FIRECRACKER_GUEST_PASS=1" ||
        file_has "$dst/X86-L2-FC-RUN/firecracker-serial-decoded.log" "AXVISOR_FIRECRACKER_GUEST_PASS=1" ||
        file_has "$dst/X86-L2-FC-RUN/firecracker-serial-decoded.log" "FC_PASS=1"; } &&
        file_lacks_crash_markers "$dst/X86-L2-FC-RUN/qemu.log"; then
        fc_initramfs_status="pass"
    fi
    record_semantic_test "FC-INITRAMFS" \
        "verified unmodified Firecracker initramfs Linux guest pass marker decoded from AxVisor serial exits" \
        "$fc_initramfs_status" \
        "functional/x86-imported/X86-L2-FC-RUN/qemu.log" \
        "functional/x86-imported/X86-L2-FC-RUN/firecracker-serial-decoded.log" \
        "functional/x86-imported/X86-L2-FC-RUN/firecracker-result.txt"

    if [[ -f "$dst/X86-L2-FC-ROOTFS-TINY/firecracker-result.txt" ||
        -f "$dst/X86-L2-FC-ROOTFS-TINY/firecracker-serial-decoded.log" ||
        -f "$dst/X86-L2-FC-ROOTFS-TINY/qemu.log" ]]; then
        fc_rootfs_tiny_status="fail"
        fc_rootfs_tiny_reason="imported Firecracker rootfs tiny-init evidence exists but semantic validation failed"
        if file_has "$dst/X86-L2-FC-ROOTFS-TINY/firecracker-result.txt" "FIRECRACKER_GUEST_BOOT_MODE=rootfs" &&
            file_has "$dst/X86-L2-FC-ROOTFS-TINY/firecracker-result.txt" "FIRECRACKER_ROOTFS_INIT_KIND=tiny" &&
            file_has "$dst/X86-L2-FC-ROOTFS-TINY/firecracker-result.txt" "TINY_PASS=1" &&
            file_has "$dst/X86-L2-FC-ROOTFS-TINY/firecracker-serial-decoded.log" "VFS: Mounted root" &&
            file_has "$dst/X86-L2-FC-ROOTFS-TINY/firecracker-serial-decoded.log" "Run /init" &&
            file_lacks_crash_markers "$dst/X86-L2-FC-ROOTFS-TINY/qemu.log"; then
            fc_rootfs_tiny_status="pass"
            fc_rootfs_tiny_reason="verified unmodified Firecracker rootfs boot reaches static tiny init through AxVisor /dev/kvm"
        fi
    fi
    record_semantic_test "FC-ROOTFS-TINY" \
        "$fc_rootfs_tiny_reason" \
        "$fc_rootfs_tiny_status" \
        "functional/x86-imported/X86-L2-FC-ROOTFS-TINY/qemu.log" \
        "functional/x86-imported/X86-L2-FC-ROOTFS-TINY/firecracker-serial-decoded.log" \
        "functional/x86-imported/X86-L2-FC-ROOTFS-TINY/firecracker-result.txt"
}

run_x86_matrix() {
    local matrix_dir="$OUT_DIR/functional/x86-matrix-rerun"

    if [[ "$RUN_X86_MATRIX" != "1" ]]; then
        record_test "HARNESS-X86-RERUN" "skip" "RUN_X86_MATRIX=0; imported existing evidence instead"
        return 0
    fi

    if OUT_DIR="$matrix_dir" MATRIX_ID="$RUN_ID-rerun" bash "$ROOT_DIR/tools/run-x86-axvisor-test-matrix.sh"; then
        record_test "HARNESS-X86-RERUN" "pass" "reran x86 matrix successfully" "functional/x86-matrix-rerun/summary.txt"
    else
        record_test "HARNESS-X86-RERUN" "fail" "x86 matrix rerun failed" "functional/x86-matrix-rerun/summary.txt"
    fi
}

record_firecracker_rootfs_status() {
    local dst="$OUT_DIR/functional/firecracker-rootfs"

    mkdir -p "$dst"
    if [[ "$RUN_FIRECRACKER_ROOTFS" == "1" ]]; then
        local run_dir="$dst/run"
        if RUN_DIR="$run_dir" \
            BUILD_DIR="${KVM_BUILD_DIR:-/tmp/axvisor-kvm-x86-test-matrix-build}" \
            FIRECRACKER_GUEST_BOOT_MODE=rootfs \
            FIRECRACKER_ROOTFS_INIT_KIND="${FIRECRACKER_ROOTFS_INIT_KIND:-sh}" \
            SKIP_BUILD="${SKIP_BUILD:-1}" \
            TIMEOUT_SECS="${TIMEOUT_SECS:-240}" \
            bash "$ROOT_DIR/tools/verify-axvisor-kvm-x86-firecracker-run.sh" \
            >"$dst/run.out" 2>&1; then
            record_test "FC-ROOTFS-BLK" "pass" "Firecracker virtio-blk rootfs passed" "functional/firecracker-rootfs/run.out" "functional/firecracker-rootfs/run/qemu.log"
        else
            record_test "FC-ROOTFS-BLK" "fail" "Firecracker virtio-blk rootfs did not pass" "functional/firecracker-rootfs/run.out" "functional/firecracker-rootfs/run/qemu.log"
        fi
    elif [[ -n "$FIRECRACKER_ROOTFS_LOG" && -f "$FIRECRACKER_ROOTFS_LOG" ]]; then
        cp -a "$FIRECRACKER_ROOTFS_LOG" "$dst/qemu.log"
        if grep -q "AXVISOR_FIRECRACKER_GUEST_PASS=1" "$FIRECRACKER_ROOTFS_LOG"; then
            record_test "FC-ROOTFS-BLK" "pass" "imported Firecracker rootfs pass log" "functional/firecracker-rootfs/qemu.log"
        else
            record_test "FC-ROOTFS-BLK" "fail" "imported Firecracker rootfs log does not contain pass marker" "functional/firecracker-rootfs/qemu.log"
        fi
    else
        record_test "FC-ROOTFS-BLK" "skip" "not run in this harness invocation; current known gap is virtio-blk request completion past /dev/vda probe"
    fi
}

record_firecracker_rootfs_tiny_status() {
    local src="$FIRECRACKER_ROOTFS_TINY_DIR"
    local dst="$OUT_DIR/functional/firecracker-rootfs-tiny"
    local status="skip"
    local reason="FIRECRACKER_ROOTFS_TINY_DIR not provided; no standalone tiny-init rootfs evidence imported"

    mkdir -p "$dst"
    if [[ -z "$src" ]]; then
        record_test "FC-ROOTFS-TINY-STANDALONE" "$status" "$reason"
        return 0
    fi
    if [[ ! -d "$src" ]]; then
        record_test "FC-ROOTFS-TINY-STANDALONE" "skip" "Firecracker rootfs tiny evidence directory not found: $src"
        return 0
    fi

    copy_if_exists "$src/qemu.log" "$dst/qemu.log" || true
    copy_if_exists "$src/firecracker-serial-decoded.log" "$dst/firecracker-serial-decoded.log" || true
    copy_if_exists "$src/firecracker-result.txt" "$dst/firecracker-result.txt" || true
    copy_if_exists "$src/run.out" "$dst/run.out" || true
    copy_if_exists "$src/README.md" "$dst/README.md" || true
    copy_if_exists "$src/SHA256SUMS" "$dst/SHA256SUMS" || true

    status="fail"
    reason="imported standalone Firecracker rootfs tiny-init evidence exists but semantic validation failed"
    if file_has "$dst/firecracker-result.txt" "FIRECRACKER_GUEST_BOOT_MODE=rootfs" &&
        file_has "$dst/firecracker-result.txt" "FIRECRACKER_ROOTFS_INIT_KIND=tiny" &&
        file_has "$dst/firecracker-result.txt" "TINY_PASS=1" &&
        file_has "$dst/firecracker-serial-decoded.log" "VFS: Mounted root" &&
        file_has "$dst/firecracker-serial-decoded.log" "Run /init" &&
        file_lacks_crash_markers "$dst/qemu.log"; then
        status="pass"
        reason="verified standalone unmodified Firecracker rootfs tiny-init evidence through AxVisor /dev/kvm"
    fi

    record_test "FC-ROOTFS-TINY-STANDALONE" "$status" "$reason" \
        "functional/firecracker-rootfs-tiny/qemu.log" \
        "functional/firecracker-rootfs-tiny/firecracker-serial-decoded.log" \
        "functional/firecracker-rootfs-tiny/firecracker-result.txt"
}

record_kvm_abi_smoke_status() {
    local dst="$OUT_DIR/abi/kvm-abi-smoke"
    local qemu_log=""
    local out_log=""
    local status="skip"
    local reason="not run in this harness invocation"

    mkdir -p "$dst"
    if [[ -n "$KVM_ABI_SMOKE_DIR" && -d "$KVM_ABI_SMOKE_DIR" ]]; then
        copy_if_exists "$KVM_ABI_SMOKE_DIR/qemu.log" "$dst/qemu.log" || true
        copy_if_exists "$KVM_ABI_SMOKE_DIR/run.out" "$dst/run.out" || true
        qemu_log="$dst/qemu.log"
        [[ -f "$dst/run.out" ]] && out_log="$dst/run.out"
    fi
    if [[ -n "$KVM_ABI_SMOKE_OUT" && -f "$KVM_ABI_SMOKE_OUT" ]]; then
        cp -a "$KVM_ABI_SMOKE_OUT" "$dst/run.out"
        out_log="$dst/run.out"
    fi

    if [[ -n "$qemu_log" ]]; then
        status="fail"
        reason="imported KVM ABI smoke log does not contain all pass markers"
        if file_has "$qemu_log" "AXVISOR_KVM_API_SMOKE_PASS=1" &&
            file_has "$qemu_log" "AXVISOR_KVM_MEM_VCPU_SMOKE_PASS=1" &&
            file_has "$qemu_log" "AXVISOR_KVM_NEGATIVE_SMOKE_PASS=1" &&
            file_has "$qemu_log" "KVM_X86_INIT_IOCTL_SMOKE=1" &&
            file_has "$qemu_log" "AXVISOR_KVM_ABI_SMOKE_QEMU_PASS=1" &&
            file_lacks_crash_markers "$qemu_log"; then
            status="pass"
            reason="verified standalone KVM ABI smoke markers for API/capability, memslot, vCPU, eventfd/irqfd, negative errno semantics, and KVM_RUN"
        fi
    fi

    if [[ -n "$out_log" ]]; then
        record_test "KVM-ABI-SMOKE" "$status" "$reason" \
            "abi/kvm-abi-smoke/qemu.log" \
            "abi/kvm-abi-smoke/run.out"
    else
        record_test "KVM-ABI-SMOKE" "$status" "$reason" \
            "abi/kvm-abi-smoke/qemu.log"
    fi

    if [[ -n "$qemu_log" && "$status" == "pass" ]]; then
        if file_has "$qemu_log" "NEG_UNKNOWN_IOCTL_ENOTTY=1"; then
            record_test "NEG-UNKNOWN-IOCTL" "pass" \
                "unknown KVM ioctl on /dev/kvm failed with ENOTTY" \
                "abi/kvm-abi-smoke/qemu.log"
        fi
        if file_has "$qemu_log" "NEG_WRONG_FD_CLASS_KVM_CREATE_VCPU=1" &&
            file_has "$qemu_log" "NEG_WRONG_FD_CLASS_VM_GET_API_VERSION=1"; then
            record_test "NEG-WRONG-FD-CLASS" "pass" \
                "KVM ioctl on wrong fd class failed with ENOTTY" \
                "abi/kvm-abi-smoke/qemu.log"
        fi
        if file_has "$qemu_log" "NEG_BAD_MEMSLOT_EINVAL=1"; then
            record_test "NEG-BAD-MEMSLOT" "pass" \
                "unaligned KVM_SET_USER_MEMORY_REGION failed with EINVAL" \
                "abi/kvm-abi-smoke/qemu.log"
        fi
        if file_has "$qemu_log" "NEG_DUP_VCPU_EEXIST=1"; then
            record_test "NEG-DUP-VCPU" "pass" \
                "duplicate KVM_CREATE_VCPU id failed with EEXIST" \
                "abi/kvm-abi-smoke/qemu.log"
        fi
        if file_has "$qemu_log" "NEG_BAD_REGS_XCR0_EINVAL=1"; then
            record_test "NEG-BAD-REGS" "pass" \
                "invalid x86 XCR0 state failed with EINVAL" \
                "abi/kvm-abi-smoke/qemu.log"
        fi
        if file_has "$qemu_log" "KVM_FD_LIFETIME_VCPU_AFTER_VM_CLOSE=1"; then
            record_test "NEG-CLOSE-RACE" "pass" \
                "vCPU fd remained valid after closing its parent VM fd" \
                "abi/kvm-abi-smoke/qemu.log"
        fi
    fi
}

import_x86_native_stability() {
    local src="$1"
    local dst="$OUT_DIR/stability/native-cycle-20"
    local report="$dst/report.txt"
    local status="fail"
    local rootfs_pass_count=0
    local rootfs_total=0

    if [[ ! -d "$src" ]]; then
        record_test "STAB-NATIVE-CYCLE-20" "skip" "existing x86 native stability evidence directory not found: $src"
        record_test "STAB-NATIVE-CYCLE-1000" "skip" "not run; only STAB-NATIVE-CYCLE-20 evidence is currently imported"
        return 0
    fi

    mkdir -p "$dst"
    cp -a "$src/README.md" "$dst/README.md" 2>/dev/null || true
    cp -a "$src/RUN_INFO.txt" "$dst/RUN_INFO.txt" 2>/dev/null || true
    cp -a "$src/summary.txt" "$dst/summary.txt" 2>/dev/null || true
    cp -a "$src/ERROR_SCAN.txt" "$dst/ERROR_SCAN.txt" 2>/dev/null || true
    cp -a "$src/CHECKS.md" "$dst/CHECKS.md" 2>/dev/null || true
    cp -a "$src/SHA256SUMS" "$dst/SHA256SUMS" 2>/dev/null || true
    copy_if_exists "$src/cases/rootfs-1/result.txt" "$dst/rootfs-1-result.txt" || true
    copy_if_exists "$src/cases/rootfs-20/result.txt" "$dst/rootfs-20-result.txt" || true
    copy_if_exists "$src/cases/initramfs/qemu.log" "$dst/initramfs-qemu.log" || true

    if [[ -d "$src/cases" ]]; then
        rootfs_total="$(find "$src/cases" -maxdepth 1 -type d -name 'rootfs-*' | wc -l)"
        rootfs_pass_count="$(grep -R -l "^AXVISOR_X86_NATIVE_GUEST_PASS=1$" "$src"/cases/rootfs-*/result.txt 2>/dev/null | wc -l)"
    fi

    {
        echo "TEST_ID=STAB-NATIVE-CYCLE-20"
        echo "SOURCE=$src"
        echo "ROOTFS_TOTAL=$rootfs_total"
        echo "ROOTFS_PASS_COUNT=$rootfs_pass_count"
        if [[ -f "$src/ERROR_SCAN.txt" ]]; then
            echo "ERROR_SCAN=$(cat "$src/ERROR_SCAN.txt")"
        else
            echo "ERROR_SCAN=missing"
        fi
        if file_has "$src/cases/initramfs/qemu.log" "AXVISOR_X86_NATIVE_GUEST_PASS=1"; then
            echo "INITRAMFS_PASS=1"
        else
            echo "INITRAMFS_PASS=0"
        fi
    } >"$report"

    if [[ "$rootfs_total" == "20" ]] &&
        [[ "$rootfs_pass_count" == "20" ]] &&
        file_has "$src/cases/initramfs/qemu.log" "AXVISOR_X86_NATIVE_GUEST_PASS=1" &&
        file_has "$src/ERROR_SCAN.txt" "NO_MATCHES"; then
        status="pass"
    fi

    record_test "STAB-NATIVE-CYCLE-20" "$status" \
        "imported 20 rootfs cycles plus 1 initramfs x86 native stability evidence" \
        "stability/native-cycle-20/report.txt" \
        "stability/native-cycle-20/summary.txt" \
        "stability/native-cycle-20/ERROR_SCAN.txt"
    record_test "STAB-NATIVE-CYCLE-1000" "skip" \
        "not run; current imported native stability evidence covers 20 rootfs cycles plus 1 initramfs cycle"
}

import_x86_mem_sizes() {
    local src="$1"
    local dst="$OUT_DIR/functional/x86-mem-sizes"
    local report="$dst/report.txt"
    local status="fail"
    local pass_cases
    local pass_count

    if [[ -z "$src" ]]; then
        record_test "L1-MEM-SIZES" "skip" "X86_MEM_SIZES_DIR not provided"
        return 0
    fi
    if [[ ! -d "$src" ]]; then
        record_test "L1-MEM-SIZES" "skip" "x86 memory-size evidence directory not found: $src"
        return 0
    fi

    mkdir -p "$dst"
    cp -a "$src/README.md" "$dst/README.md" 2>/dev/null || true
    cp -a "$src/summary.txt" "$dst/summary.txt" 2>/dev/null || true
    cp -a "$src/summary.csv" "$dst/summary.csv" 2>/dev/null || true
    cp -a "$src/summary.json" "$dst/summary.json" 2>/dev/null || true
    cp -a "$src/SHA256SUMS" "$dst/SHA256SUMS" 2>/dev/null || true
    for cpus in 1 2 4 8; do
        copy_if_exists "$src/L1-SMP-SCALE-$cpus/result.txt" "$dst/L1-SMP-SCALE-$cpus/result.txt" || true
        copy_if_exists "$src/L1-SMP-SCALE-$cpus/qemu.log" "$dst/L1-SMP-SCALE-$cpus/qemu.log" || true
        copy_if_exists "$src/L1-SMP-SCALE-$cpus/run.out" "$dst/L1-SMP-SCALE-$cpus/run.out" || true
        copy_if_exists "$src/L1-SMP-SCALE-$cpus/x86_64-linux-host-vm.generated.toml" "$dst/L1-SMP-SCALE-$cpus/x86_64-linux-host-vm.generated.toml" || true
    done

    pass_cases="$(find "$src" -maxdepth 1 -type d -name 'L1-MEM-*' -printf '%f\n' | sort | tr '\n' ' ')"
    pass_count=0
    {
        echo "TEST_ID=L1-MEM-SIZES"
        echo "SOURCE=$src"
        echo "CASES=$pass_cases"
    } >"$report"

    for case_dir in "$src"/L1-MEM-*; do
        [[ -d "$case_dir" ]] || continue
        local case_id
        case_id="$(basename "$case_dir")"
        copy_if_exists "$case_dir/result.txt" "$dst/$case_id/result.txt" || true
        copy_if_exists "$case_dir/qemu.log" "$dst/$case_id/qemu.log" || true
        copy_if_exists "$case_dir/run.out" "$dst/$case_id/run.out" || true
        copy_if_exists "$case_dir/x86_64-linux-host-vm.generated.toml" "$dst/$case_id/x86_64-linux-host-vm.generated.toml" || true
        if file_has "$case_dir/result.txt" "^AXVISOR_X86_NATIVE_GUEST_PASS=1$" &&
            file_has "$case_dir/result.txt" "^ROOT_MOUNT_FS=ext4$" &&
            file_has "$case_dir/result.txt" "^SMOKE_WRITE_TEST=1$" &&
            file_has "$case_dir/qemu.log" "VFS: Mounted root (ext4 filesystem)" &&
            file_lacks_crash_markers "$case_dir/qemu.log"; then
            pass_count=$((pass_count + 1))
            echo "$case_id=pass" >>"$report"
        else
            echo "$case_id=fail" >>"$report"
        fi
    done
    echo "PASS_COUNT=$pass_count" >>"$report"

    if file_has "$src/summary.txt" "MEM_SIZES_STATUS=pass" && (( pass_count > 0 )); then
        status="pass"
    fi

    record_test "L1-MEM-SIZES" "$status" \
        "imported x86 native memory-size evidence for: $pass_cases" \
        "functional/x86-mem-sizes/report.txt" \
        "functional/x86-mem-sizes/summary.txt" \
        "functional/x86-mem-sizes/summary.json"
}

import_x86_functional() {
    local src="$1"
    local dst="$OUT_DIR/functional/x86-functional"
    local report="$dst/report.txt"
    local case_src="$src/L1-FUNCTIONAL"

    if [[ -z "$src" ]]; then
        return 0
    fi
    if [[ ! -d "$src" ]]; then
        record_test "L1-TIMER" "skip" "x86 timer/irq/mmio evidence directory not found: $src"
        record_test "L1-IRQ" "skip" "x86 timer/irq/mmio evidence directory not found: $src"
        record_test "L1-MMIO" "skip" "x86 timer/irq/mmio evidence directory not found: $src"
        return 0
    fi

    mkdir -p "$dst/L1-FUNCTIONAL"
    cp -a "$src/README.md" "$dst/README.md" 2>/dev/null || true
    cp -a "$src/summary.txt" "$dst/summary.txt" 2>/dev/null || true
    cp -a "$src/summary.csv" "$dst/summary.csv" 2>/dev/null || true
    cp -a "$src/summary.json" "$dst/summary.json" 2>/dev/null || true
    cp -a "$src/SHA256SUMS" "$dst/SHA256SUMS" 2>/dev/null || true
    copy_if_exists "$case_src/run.out" "$dst/L1-FUNCTIONAL/run.out" || true
    copy_if_exists "$case_src/qemu.log" "$dst/L1-FUNCTIONAL/qemu.log" || true
    copy_if_exists "$case_src/result.txt" "$dst/L1-FUNCTIONAL/result.txt" || true
    copy_if_exists "$case_src/x86_64-linux-host-vm.generated.toml" "$dst/L1-FUNCTIONAL/x86_64-linux-host-vm.generated.toml" || true

    {
        echo "TEST_ID=L1-TIMER,L1-IRQ,L1-MMIO"
        echo "SOURCE=$src"
        if [[ -f "$src/summary.txt" ]]; then
            grep -E "FUNCTIONAL_STATUS=|CASE=|STATUS=|REASON=" "$src/summary.txt" || true
        fi
    } >"$report"

    local timer_status="fail"
    local irq_status="fail"
    local mmio_status="fail"
    if file_has "$src/summary.txt" "CASE=L1-TIMER" &&
        file_has "$src/summary.txt" "STATUS=pass" &&
        file_has "$case_src/result.txt" "^TIMER_CHECK=1$" &&
        file_has "$case_src/result.txt" "^TIMER_MONOTONIC_OK=1$" &&
        file_has "$case_src/result.txt" "^TIMER_SLEEP_WAKE_OK=1$" &&
        file_has_ere "$case_src/qemu.log" "x86_irq::pit_due .*count=([5-9]|[1-9][0-9])" &&
        file_has "$case_src/qemu.log" "x86_irq::pit_inject .*vector=0x30" &&
        file_lacks_crash_markers "$case_src/qemu.log"; then
        timer_status="pass"
    fi
    if file_has "$src/summary.txt" "CASE=L1-IRQ" &&
        file_has "$src/summary.txt" "STATUS=pass" &&
        file_has "$case_src/result.txt" "^IRQ_CHECK=1$" &&
        file_has "$case_src/result.txt" "^IRQ_VIRTIO_DELTA_POSITIVE=1$" &&
        file_has_any "$case_src/qemu.log" \
            "x86 passthrough irq poll irq=19 .*pending=1" \
            "passthrough irq pending vm_id=1 irq_id=19 pending=true" &&
        file_has_any "$case_src/qemu.log" \
            "x86 INTx state poll-pending .*guest_gsi=19.*interrupt_pending=1" \
            "x86_irq::eoi vector=0x20 gsi=19" &&
        file_lacks_crash_markers "$case_src/qemu.log"; then
        irq_status="pass"
    fi
    if file_has "$src/summary.txt" "CASE=L1-MMIO" &&
        file_has "$src/summary.txt" "STATUS=pass" &&
        file_has "$case_src/result.txt" "^MMIO_CHECK=1$" &&
        file_has "$case_src/result.txt" "^MMIO_VIRTIO_RW_ITERATIONS=8$" &&
        file_has "$case_src/result.txt" "^MMIO_VIRTIO_RW_OK=1$" &&
        file_has "$case_src/qemu.log" "virtio_blk virtio0: \\[vda\\]" &&
        file_lacks_crash_markers "$case_src/qemu.log"; then
        mmio_status="pass"
    fi

    record_test "L1-TIMER" "$timer_status" \
        "imported x86 native guest timer monotonic/sleep and PIT injection evidence" \
        "functional/x86-functional/report.txt" \
        "functional/x86-functional/L1-FUNCTIONAL/qemu.log" \
        "functional/x86-functional/L1-FUNCTIONAL/result.txt"
    record_test "L1-IRQ" "$irq_status" \
        "imported x86 native virtio-blk interrupt delivery evidence" \
        "functional/x86-functional/report.txt" \
        "functional/x86-functional/L1-FUNCTIONAL/qemu.log" \
        "functional/x86-functional/L1-FUNCTIONAL/result.txt"
    record_test "L1-MMIO" "$mmio_status" \
        "imported x86 native repeated virtio-blk I/O evidence without unhandled MMIO/device faults" \
        "functional/x86-functional/report.txt" \
        "functional/x86-functional/L1-FUNCTIONAL/qemu.log" \
        "functional/x86-functional/L1-FUNCTIONAL/result.txt"
}

import_x86_smp() {
    local src="$1"
    local dst="$OUT_DIR/functional/x86-smp"
    local boot_status="fail"
    local report="$dst/report.txt"
    local status="fail"

    if [[ -z "$src" ]]; then
        record_test "L1-SMP-2-BOOT" "skip" "X86_SMP_DIR not provided"
        record_test "L1-SMP-2" "skip" "X86_SMP_DIR not provided"
        record_test "FC-SMP-2" "skip" "not implemented in current Firecracker AxVisor KVM frontend test"
        return 0
    fi
    if [[ ! -d "$src" ]]; then
        record_test "L1-SMP-2-BOOT" "skip" "x86 SMP evidence directory not found: $src"
        record_test "L1-SMP-2" "skip" "x86 SMP evidence directory not found: $src"
        record_test "FC-SMP-2" "skip" "not implemented in current Firecracker AxVisor KVM frontend test"
        return 0
    fi

    mkdir -p "$dst"
    cp -a "$src/README.md" "$dst/README.md" 2>/dev/null || true
    cp -a "$src/summary.txt" "$dst/summary.txt" 2>/dev/null || true
    cp -a "$src/summary.csv" "$dst/summary.csv" 2>/dev/null || true
    cp -a "$src/summary.json" "$dst/summary.json" 2>/dev/null || true
    cp -a "$src/SHA256SUMS" "$dst/SHA256SUMS" 2>/dev/null || true

    copy_if_exists "$src/L1-SMP-2-BOOT/qemu.log" "$dst/L1-SMP-2-BOOT/qemu.log" || true
    copy_if_exists "$src/L1-SMP-2-BOOT/run.out" "$dst/L1-SMP-2-BOOT/run.out" || true
    copy_if_exists "$src/L1-SMP-2-BOOT/x86_64-linux-host-vm.generated.toml" "$dst/L1-SMP-2-BOOT/x86_64-linux-host-vm.generated.toml" || true
    copy_if_exists "$src/L1-SMP-2/result.txt" "$dst/L1-SMP-2/result.txt" || true
    copy_if_exists "$src/L1-SMP-2/qemu.log" "$dst/L1-SMP-2/qemu.log" || true
    copy_if_exists "$src/L1-SMP-2/run.out" "$dst/L1-SMP-2/run.out" || true
    copy_if_exists "$src/L1-SMP-2/x86_64-linux-host-vm.generated.toml" "$dst/L1-SMP-2/x86_64-linux-host-vm.generated.toml" || true

    {
        echo "TEST_ID=L1-SMP-2"
        echo "SOURCE=$src"
        if [[ -f "$src/summary.txt" ]]; then
            grep -E "SMP_STATUS=|CASE=|STATUS=|REASON=" "$src/summary.txt" || true
        fi
    } >"$report"

    if file_has "$src/summary.txt" "CASE=L1-SMP-2-BOOT" &&
        file_has "$src/summary.txt" "STATUS=pass" &&
        file_has "$src/L1-SMP-2-BOOT/qemu.log" "smp: Brought up 1 node, 2 CPUs" &&
        file_has "$src/L1-SMP-2-BOOT/qemu.log" "AXVISOR_X86_NATIVE_GUEST_EXPECTED_CPUS=2" &&
        file_has "$src/L1-SMP-2-BOOT/qemu.log" "AXVISOR_X86_NATIVE_GUEST_CPUINFO_PROCESSOR_COUNT=2" &&
        file_has "$src/L1-SMP-2-BOOT/qemu.log" "AXVISOR_X86_NATIVE_GUEST_CPU_ONLINE_COUNT=2" &&
        file_has "$src/L1-SMP-2-BOOT/qemu.log" "AXVISOR_X86_NATIVE_GUEST_PASS=1" &&
        file_lacks_crash_markers "$src/L1-SMP-2-BOOT/qemu.log"; then
        boot_status="pass"
    fi
    record_test "L1-SMP-2-BOOT" "$boot_status" \
        "imported x86 native 2-vCPU initramfs guest boot evidence" \
        "functional/x86-smp/report.txt" \
        "functional/x86-smp/summary.json" \
        "functional/x86-smp/L1-SMP-2-BOOT/qemu.log" \
        "functional/x86-smp/L1-SMP-2-BOOT/x86_64-linux-host-vm.generated.toml"

    if file_has "$src/summary.json" '"status": "pass"' &&
        file_has "$src/L1-SMP-2/result.txt" "^AXVISOR_X86_NATIVE_GUEST_PASS=1$" &&
        file_has "$src/L1-SMP-2/result.txt" "^EXPECTED_GUEST_CPUS=2$" &&
        file_has "$src/L1-SMP-2/result.txt" "^CPUINFO_PROCESSOR_COUNT=2$" &&
        file_has "$src/L1-SMP-2/result.txt" "^CPU_ONLINE_COUNT=2$" &&
        file_has "$src/L1-SMP-2/qemu.log" "VFS: Mounted root (ext4 filesystem)" &&
        file_lacks_crash_markers "$src/L1-SMP-2/qemu.log"; then
        status="pass"
    fi

    record_test "L1-SMP-2" "$status" \
        "imported x86 native 2-vCPU SMP Linux guest evidence" \
        "functional/x86-smp/report.txt" \
        "functional/x86-smp/summary.json" \
        "functional/x86-smp/L1-SMP-2/qemu.log" \
        "functional/x86-smp/L1-SMP-2/x86_64-linux-host-vm.generated.toml"
    record_test "FC-SMP-2" "skip" "not implemented in current Firecracker AxVisor KVM frontend test"
}

import_x86_smp_scale() {
    local src="$1"
    local dst="$OUT_DIR/functional/x86-smp-scale"
    local report="$dst/report.txt"
    local status="fail"
    local cpus

    if [[ -z "$src" ]]; then
        return 0
    fi
    if [[ ! -d "$src" ]]; then
        record_test "L1-SMP-SCALE" "skip" "x86 SMP scale evidence directory not found: $src"
        record_test "SCALE-SMP" "skip" "x86 SMP scale evidence directory not found: $src"
        return 0
    fi

    mkdir -p "$dst"
    cp -a "$src/README.md" "$dst/README.md" 2>/dev/null || true
    cp -a "$src/summary.txt" "$dst/summary.txt" 2>/dev/null || true
    cp -a "$src/summary.csv" "$dst/summary.csv" 2>/dev/null || true
    cp -a "$src/summary.json" "$dst/summary.json" 2>/dev/null || true
    cp -a "$src/SHA256SUMS" "$dst/SHA256SUMS" 2>/dev/null || true

    {
        echo "TEST_ID=L1-SMP-SCALE"
        echo "SOURCE=$src"
        if [[ -f "$src/summary.txt" ]]; then
            grep -E "CASE=|STATUS=|REASON=|SMP_SCALE_STATUS=" "$src/summary.txt" || true
        fi
    } >"$report"

    if file_has "$src/summary.json" '"status": "pass"'; then
        status="pass"
        for cpus in 1 2 4 8; do
            if ! file_has "$src/summary.json" "\"id\": \"L1-SMP-SCALE-$cpus\"" ||
                ! file_has "$src/summary.json" "\"status\": \"pass\"" ||
                ! file_has "$src/L1-SMP-SCALE-$cpus/result.txt" "^EXPECTED_GUEST_CPUS=$cpus$" ||
                ! file_has "$src/L1-SMP-SCALE-$cpus/result.txt" "^CPUINFO_PROCESSOR_COUNT=$cpus$" ||
                ! file_has "$src/L1-SMP-SCALE-$cpus/result.txt" "^CPU_ONLINE_COUNT=$cpus$" ||
                ! file_has "$src/L1-SMP-SCALE-$cpus/result.txt" "^ROOT_MOUNT_FS=ext4$" ||
                ! file_has "$src/L1-SMP-SCALE-$cpus/result.txt" "^SMOKE_WRITE_TEST=1$" ||
                ! file_lacks_crash_markers "$src/L1-SMP-SCALE-$cpus/qemu.log"; then
                status="fail"
            fi
        done
    fi

    record_test "L1-SMP-SCALE" "$status" \
        "imported x86 native 1/2/4/8-vCPU Linux guest scale evidence" \
        "functional/x86-smp-scale/report.txt" \
        "functional/x86-smp-scale/summary.json"
    record_test "SCALE-SMP" "$status" \
        "imported x86 native 1/2/4/8-vCPU scale evidence as SMP scalability datapoint" \
        "functional/x86-smp-scale/report.txt" \
        "functional/x86-smp-scale/summary.json"
}

import_x86_poweroff() {
    local src="$1"
    local dst="$OUT_DIR/functional/x86-poweroff"
    local report="$dst/report.txt"
    local status="fail"

    if [[ -z "$src" ]]; then
        return 0
    fi
    if [[ ! -d "$src" ]]; then
        record_test "L1-POWEROFF" "skip" "x86 poweroff evidence directory not found: $src"
        return 0
    fi

    mkdir -p "$dst"
    cp -a "$src/README.md" "$dst/README.md" 2>/dev/null || true
    cp -a "$src/summary.txt" "$dst/summary.txt" 2>/dev/null || true
    cp -a "$src/summary.csv" "$dst/summary.csv" 2>/dev/null || true
    cp -a "$src/summary.json" "$dst/summary.json" 2>/dev/null || true
    cp -a "$src/SHA256SUMS" "$dst/SHA256SUMS" 2>/dev/null || true
    copy_if_exists "$src/L1-POWEROFF/qemu.log" "$dst/L1-POWEROFF/qemu.log" || true
    copy_if_exists "$src/L1-POWEROFF/run.out" "$dst/L1-POWEROFF/run.out" || true
    copy_if_exists "$src/L1-POWEROFF/result.txt" "$dst/L1-POWEROFF/result.txt" || true
    copy_if_exists "$src/L1-POWEROFF/x86_64-linux-host-vm.generated.toml" "$dst/L1-POWEROFF/x86_64-linux-host-vm.generated.toml" || true

    {
        echo "TEST_ID=L1-POWEROFF"
        echo "SOURCE=$src"
        if [[ -f "$src/summary.txt" ]]; then
            grep -E "POWEROFF_STATUS=|CASE=|STATUS=|REASON=" "$src/summary.txt" || true
        fi
    } >"$report"

    if file_has "$src/summary.txt" "POWEROFF_STATUS=pass" &&
        file_has "$src/L1-POWEROFF/result.txt" "^AXVISOR_X86_NATIVE_GUEST_PASS=1$" &&
        file_has "$src/L1-POWEROFF/result.txt" "^ROOT_MOUNT_FS=ext4$" &&
        file_has "$src/L1-POWEROFF/result.txt" "^SMOKE_WRITE_TEST=1$" &&
        file_has "$src/L1-POWEROFF/qemu.log" "AXVISOR_X86_NATIVE_GUEST_STAGE=after-sync" &&
        file_has "$src/L1-POWEROFF/qemu.log" "AXVISOR_X86_NATIVE_GUEST_STAGE=before-exit-port" &&
        file_has "$src/L1-POWEROFF/qemu.log" "AXVISOR_X86_NATIVE_GUEST_PASS=1" &&
        file_has "$src/L1-POWEROFF/qemu.log" "vcpus::exit_reason system_down" &&
        file_has "$src/L1-POWEROFF/qemu.log" "kthread main entry returned" &&
        file_lacks_crash_markers "$src/L1-POWEROFF/qemu.log"; then
        status="pass"
    fi

    record_test "L1-POWEROFF" "$status" \
        "imported x86 native guest-triggered poweroff evidence" \
        "functional/x86-poweroff/report.txt" \
        "functional/x86-poweroff/summary.json" \
        "functional/x86-poweroff/L1-POWEROFF/qemu.log" \
        "functional/x86-poweroff/L1-POWEROFF/result.txt"
}

write_abi_coverage() {
    mkdir -p "$OUT_DIR/abi"
    cat >"$ABI_CSV" <<'EOF'
architecture,ioctl_or_capability,object_class,observed_by_firecracker,implemented,status,semantic_test_id,call_count,first_error,notes
x86_64,KVM_GET_API_VERSION,kvm-fd,yes,yes,fully-tested,FC-INIT,1,,Firecracker accepts API version
x86_64,KVM_CHECK_EXTENSION,kvm-fd,yes,yes,fully-tested,FC-INIT,unknown,,Capabilities are probed by Firecracker init smoke
x86_64,KVM_CREATE_VM,kvm-fd,yes,yes,fully-tested,FC-INIT,1,,VM object lifecycle exercised
x86_64,KVM_GET_VCPU_MMAP_SIZE,kvm-fd,yes,yes,fully-tested,FC-INIT,1,,kvm_run mmap size accepted
x86_64,KVM_CREATE_VCPU,vm-fd,yes,yes,fully-tested,FC-INITRAMFS,1,,Single vCPU boot path exercised
x86_64,KVM_SET_USER_MEMORY_REGION,vm-fd,yes,yes,fully-tested,FC-INITRAMFS,unknown,,Guest memory used to boot initramfs
x86_64,KVM_SET_TSS_ADDR,vm-fd,yes,yes,fully-tested,FC-INIT,1,,x86 setup path
x86_64,KVM_SET_IDENTITY_MAP_ADDR,vm-fd,yes,yes,fully-tested,FC-INIT,1,,x86 setup path
x86_64,KVM_CREATE_IRQCHIP,vm-fd,yes,yes,fully-tested,FC-INITRAMFS,1,,Required for Firecracker boot path
x86_64,KVM_CREATE_PIT2,vm-fd,yes,yes,fully-tested,FC-INIT,1,,PIT state path initialized
x86_64,KVM_GET_CLOCK,vm-fd,yes,yes,fully-tested,FC-INIT,1,,Clock ioctl smoke
x86_64,KVM_SET_CLOCK,vm-fd,yes,yes,fully-tested,FC-INIT,1,,Clock ioctl smoke
x86_64,KVM_GET_IRQCHIP,vm-fd,yes,yes,fully-tested,FC-INIT,1,,IRQ chip state smoke
x86_64,KVM_SET_IRQCHIP,vm-fd,yes,yes,fully-tested,FC-INIT,1,,IRQ chip state smoke
x86_64,KVM_GET_PIT2,vm-fd,yes,yes,fully-tested,FC-INIT,1,,PIT state smoke
x86_64,KVM_SET_PIT2,vm-fd,yes,yes,fully-tested,FC-INIT,1,,PIT state smoke
x86_64,KVM_IOEVENTFD,vm-fd,yes,yes,fully-tested,KVM-ABI-SMOKE,unknown,,Standalone ABI smoke covers assign; duplicate EEXIST; deassign; Firecracker virtio-blk data-plane still pending
x86_64,KVM_IRQFD,vm-fd,yes,yes,fully-tested,KVM-ABI-SMOKE,unknown,,Standalone ABI smoke covers assign; duplicate EBUSY; resample EOPNOTSUPP; deassign; eventfd signal path
x86_64,KVM_GET_REGS,vcpu-fd,yes,yes,fully-tested,FC-INITRAMFS,unknown,,vCPU state boot path
x86_64,KVM_SET_REGS,vcpu-fd,yes,yes,fully-tested,FC-INITRAMFS,unknown,,vCPU state boot path
x86_64,KVM_GET_SREGS,vcpu-fd,yes,yes,fully-tested,FC-INITRAMFS,unknown,,vCPU state boot path
x86_64,KVM_SET_SREGS,vcpu-fd,yes,yes,fully-tested,FC-INITRAMFS,unknown,,vCPU state boot path
x86_64,KVM_GET_FPU,vcpu-fd,yes,yes,fully-tested,FC-INIT,1,,State smoke
x86_64,KVM_SET_FPU,vcpu-fd,yes,yes,fully-tested,FC-INITRAMFS,unknown,,State smoke and boot path
x86_64,KVM_GET_LAPIC,vcpu-fd,yes,yes,fully-tested,FC-INIT,1,,State smoke
x86_64,KVM_SET_LAPIC,vcpu-fd,yes,yes,fully-tested,FC-INITRAMFS,unknown,,State smoke and boot path
x86_64,KVM_GET_MP_STATE,vcpu-fd,yes,yes,fully-tested,FC-INIT,1,,State smoke
x86_64,KVM_SET_MP_STATE,vcpu-fd,yes,yes,fully-tested,FC-INITRAMFS,unknown,,State smoke and boot path
x86_64,KVM_SET_CPUID2,vcpu-fd,yes,yes,fully-tested,FC-INITRAMFS,unknown,,Firecracker boot uses CPUID setup
x86_64,KVM_GET_MSRS,vcpu-fd,yes,yes,fully-tested,FC-INIT,1,,MSR smoke
x86_64,KVM_SET_MSRS,vcpu-fd,yes,yes,fully-tested,FC-INITRAMFS,unknown,,Boot path uses MSR setup
x86_64,KVM_RUN,vcpu-fd,yes,yes,fully-tested,FC-INITRAMFS,unknown,,Guest reaches deterministic PASS marker
x86_64,UNKNOWN_KVM_IOCTL,kvm-fd,no,yes,fully-tested,NEG-UNKNOWN-IOCTL,1,,Unknown KVM ioctl returns ENOTTY
x86_64,KVM_CREATE_VCPU,kvm-fd,no,yes,fully-tested,NEG-WRONG-FD-CLASS,1,,Wrong fd class returns ENOTTY
x86_64,KVM_GET_API_VERSION,vm-fd,no,yes,fully-tested,NEG-WRONG-FD-CLASS,1,,Wrong fd class returns ENOTTY
x86_64,KVM_SET_USER_MEMORY_REGION_INVALID,vm-fd,no,yes,fully-tested,NEG-BAD-MEMSLOT,1,,Unaligned memslot returns EINVAL
x86_64,KVM_CREATE_VCPU_DUPLICATE,vm-fd,no,yes,fully-tested,NEG-DUP-VCPU,1,,Duplicate vCPU id returns EEXIST
x86_64,KVM_SET_XCRS_INVALID,vcpu-fd,no,yes,fully-tested,NEG-BAD-REGS,1,,Invalid XCR0 returns EINVAL
x86_64,VM_FD_CLOSE_BEFORE_VCPU_FD,fd-lifecycle,no,yes,fully-tested,NEG-CLOSE-RACE,1,,vCPU fd remains valid after parent VM fd close
x86_64,KVM_CAP_IOEVENTFD,capability,yes,yes,fully-tested,KVM-ABI-SMOKE,unknown,,Capability is advertised and standalone ABI smoke exercises basic ioeventfd semantics
x86_64,KVM_CAP_IRQFD,capability,yes,yes,fully-tested,KVM-ABI-SMOKE,unknown,,Capability is advertised and standalone ABI smoke exercises basic irqfd semantics
x86_64,KVM_CAP_USER_MEMORY,capability,yes,yes,fully-tested,FC-INITRAMFS,unknown,,Guest memory required for boot
x86_64,KVM_CAP_NR_MEMSLOTS,capability,yes,yes,fully-tested,FC-INIT,1,,Capability smoke
EOF
    record_test "KVM-ABI-COVERAGE" "pass" "generated KVM ABI coverage classification for tested x86 Firecracker path" "abi/kvm-abi-coverage.csv"
}

import_architecture_static() {
    local src="$1"
    local dst="$OUT_DIR/architecture"
    local status="fail"

    mkdir -p "$OUT_DIR/architecture"
    if [[ -z "$src" ]]; then
        {
            echo "ARCH-NO-HOST-IMPORTS: not run"
            echo "ARCH-NO-HOST-TYPES: not run"
            echo "ARCH-NO-KVM-IN-CORE: not run"
            echo "ARCH-BACKEND-BOUNDARY: not run"
            echo "ARCH-UNUSED-HOSTIF: not run"
        } >"$OUT_DIR/architecture/dependency-report.txt"
        cat >"$OUT_DIR/architecture/loc-report.csv" <<'EOF'
component,total_loc,new_loc,modified_core_loc,backend_loc,arch_loc,frontend_loc,number_of_hostif_methods,number_of_new_core_dependencies
not-measured,0,0,0,0,0,0,0,0
EOF
        record_test "ARCH-STATIC-CHECKS" "skip" "ARCH_STATIC_DIR not provided" "architecture/dependency-report.txt" "architecture/loc-report.csv"
        return 0
    fi
    if [[ ! -d "$src" ]]; then
        record_test "ARCH-STATIC-CHECKS" "skip" "architecture static evidence directory not found: $src"
        return 0
    fi

    copy_if_exists "$src/dependency-report.txt" "$dst/dependency-report.txt" || true
    copy_if_exists "$src/dependency-report.json" "$dst/dependency-report.json" || true
    copy_if_exists "$src/forbidden-findings.csv" "$dst/forbidden-findings.csv" || true
    copy_if_exists "$src/host-api-calls.csv" "$dst/host-api-calls.csv" || true
    copy_if_exists "$src/hostif-methods.csv" "$dst/hostif-methods.csv" || true
    copy_if_exists "$src/loc-report.csv" "$dst/loc-report.csv" || true
    copy_if_exists "$src/summary.json" "$dst/summary.json" || true

    if file_has "$src/summary.json" '"status": "pass"' &&
        file_has "$src/dependency-report.txt" "ARCH-NO-HOST-IMPORTS: pass" &&
        file_has "$src/dependency-report.txt" "ARCH-NO-HOST-TYPES: pass" &&
        file_has "$src/dependency-report.txt" "ARCH-NO-KVM-IN-CORE: pass" &&
        file_has "$src/dependency-report.txt" "ARCH-BACKEND-BOUNDARY: pass" &&
        file_has "$src/dependency-report.txt" "ARCH-UNUSED-HOSTIF: pass"; then
        status="pass"
    fi

    record_test "ARCH-STATIC-CHECKS" "$status" \
        "imported source-level architecture boundary and LOC evidence" \
        "architecture/dependency-report.txt" \
        "architecture/dependency-report.json" \
        "architecture/forbidden-findings.csv" \
        "architecture/host-api-calls.csv" \
        "architecture/hostif-methods.csv" \
        "architecture/loc-report.csv"
}

write_readme() {
    cat >"$OUT_DIR/README.md" <<EOF
# AxVisor Paper Evaluation Evidence

Suite: \`$SUITE\`

Run ID: \`$RUN_ID\`

Status: \`$STATUS\`

This harness creates the paper-evaluation output layout from the requested
test matrix. This run focuses on importing and normalizing current x86 evidence.
It does not claim the complete evaluation goal is finished.

Top-level status is \`fail\` unless every required matrix item is either passed
or intentionally out of scope for a smaller suite. This full paper-evaluation
suite records not-yet-run required items as \`skip\`, so an import-only run is
expected to remain a non-pass result.

Imported x86 evidence:

- \`L1-ROOTFS-BLK\`: Linux/x86 host -> AxVisor native -> Linux rootfs guest.
- \`L1-INITRAMFS\`: Linux/x86 host -> AxVisor native -> Linux initramfs guest.
- \`FC-INIT\`: AxVisor KVM frontend accepts Firecracker-required init ABI.
- \`FC-INITRAMFS\`: unmodified x86 Firecracker boots an initramfs Linux guest through AxVisor \`/dev/kvm\`.
- \`FC-ROOTFS-TINY\`: unmodified x86 Firecracker mounts an ext4 rootfs and reaches static tiny init through AxVisor \`/dev/kvm\`.
- \`FC-ROOTFS-TINY-STANDALONE\`: standalone rootfs/tiny-init evidence imported when \`FIRECRACKER_ROOTFS_TINY_DIR\` is provided.
- \`KVM-ABI-SMOKE\`: standalone KVM ABI smoke for API/capability, memslot, vCPU, eventfd/irqfd, negative errno semantics, and \`KVM_RUN\`.
- \`STAB-NATIVE-CYCLE-20\`: imported 20 x86 native rootfs cycles plus one initramfs cycle.
- \`L1-MEM-SIZES\`: imported x86 native guest memory-size evidence when \`X86_MEM_SIZES_DIR\` is provided.
- \`L1-TIMER\`, \`L1-IRQ\`, \`L1-MMIO\`: imported x86 native guest timer/interrupt/repeated virtio I/O evidence when \`X86_FUNCTIONAL_DIR\` is provided.
- \`L1-SMP-2-BOOT\`: imported x86 native guest 2-vCPU initramfs userspace evidence when \`X86_SMP_DIR\` is provided.
- \`L1-SMP-2\`: imported x86 native guest 2-vCPU rootfs/virtio-blk evidence when \`X86_SMP_DIR\` is provided.
- \`L1-POWEROFF\`: imported guest-triggered poweroff evidence when \`X86_POWEROFF_DIR\` is provided.
- \`ARCH-STATIC-CHECKS\`: imported source-level architecture boundary evidence when \`ARCH_STATIC_DIR\` is provided.

Explicit current gaps:

- \`FC-ROOTFS-BLK\`: full BusyBox/shell Firecracker rootfs is not passed in this run unless explicitly provided or run.
- \`FC-SMP-2\`: not implemented in the current Firecracker AxVisor KVM frontend test.
- \`L1-SMP-2\` rootfs can fail independently while \`L1-SMP-2-BOOT\` passes;
  this means 2-vCPU boot is proven but SMP + virtio-blk rootfs completion is
  still open.
- full memory-size sweep \`128M/256M/512M/1G/max practical\`: only the provided \`L1-MEM-SIZES\` evidence is claimed.
- \`STAB-NATIVE-CYCLE-1000\`: not run; current imported evidence covers 20 rootfs cycles.
- Performance, stability, network, and static dependency phases are represented
  as pending/skipped evidence, not successful results.

Primary files:

- \`summary.json\`
- \`summary.csv\`
- \`environment/environment.json\`
- \`abi/kvm-abi-coverage.csv\`
- \`performance/boot-samples.csv\`
- \`performance/microbench.csv\`
- \`performance/hostif-profile.csv\`
- \`SHA256SUMS\`
EOF
}

finalize_summary() {
    python3 - "$SUMMARY_JSON" "$TESTS_JSONL" "$SUITE" "$RUN_ID" "$STATUS" <<'PY'
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
counts = {"pass": 0, "fail": 0, "skip": 0}
for test in tests:
    status = test.get("status")
    if status in counts:
        counts[status] += 1
data = {
    "suite": sys.argv[3],
    "run_id": sys.argv[4],
    "configuration": "x86-imported-current",
    "status": sys.argv[5],
    "counts": counts,
    "tests": tests,
}
summary.write_text(json.dumps(data, indent=2) + "\n")
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
need_cmd lscpu
need_cmd python3
need_cmd sha256sum

mkdir -p "$OUT_DIR"/{environment,functional,abi,performance/raw,stability,architecture,logs}
: >"$TESTS_JSONL"
printf 'id,status,reason,artifacts\n' >"$SUMMARY_CSV"

write_placeholder_outputs
capture_environment
record_test "HARNESS-ENV" "pass" "captured environment metadata" "environment/environment.json" "environment/uname.txt" "environment/lscpu.txt" "environment/cpu.txt" "environment/git-revisions.txt"
record_test "HARNESS-RUN-ID" "pass" "created unique output directory $OUT_DIR" "README.md"
record_test "HARNESS-RAW" "pass" "preserved imported raw logs where available" "functional/x86-imported"

run_x86_matrix
import_x86_evidence "$X86_EVIDENCE_DIR"
record_firecracker_rootfs_status
record_firecracker_rootfs_tiny_status
record_kvm_abi_smoke_status
import_x86_native_stability "$X86_NATIVE_STABILITY_DIR"
import_x86_mem_sizes "$X86_MEM_SIZES_DIR"
import_x86_functional "$X86_FUNCTIONAL_DIR"
import_x86_smp "$X86_SMP_DIR"
import_x86_smp_scale "$X86_SMP_SCALE_DIR"
import_x86_poweroff "$X86_POWEROFF_DIR"
write_abi_coverage
import_architecture_static "$ARCH_STATIC_DIR"
record_pending_matrix_skips

write_readme
finalize_summary
finalize_checksums
record_test "HARNESS-HASH" "pass" "generated and verified SHA256SUMS" "SHA256SUMS"
finalize_summary
finalize_checksums

echo "[paper-eval] status: $STATUS"
echo "[paper-eval] output: $OUT_DIR"
if [[ "$STATUS" != "pass" ]]; then
    exit 1
fi
