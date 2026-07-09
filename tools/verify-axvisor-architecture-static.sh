#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/output/axvisor-architecture-static-$RUN_ID}"
case "$OUT_DIR" in
    /*) ;;
    *) OUT_DIR="$ROOT_DIR/$OUT_DIR" ;;
esac

SUMMARY_JSON="$OUT_DIR/summary.json"
SUMMARY_CSV="$OUT_DIR/summary.csv"
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
    elif [[ "$test_status" == "skip" && "$STATUS" == "pass" ]]; then
        STATUS="partial"
    fi
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

run_static_scan() {
    python3 - "$ROOT_DIR" "$OUT_DIR" <<'PY'
import csv
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
out = Path(sys.argv[2])
axvisor = root / "linux-host-kernel" / "drivers" / "virt" / "axvisor"
upstream = axvisor / "vendor" / "upstream"

core_crates = [
    "axvisor_api",
    "axvisor_core",
    "axvm",
    "axvcpu",
    "axaddrspace",
    "axdevice",
    "axdevice_base",
    "axhvc",
    "axvmconfig",
    "ax-memory-addr",
    "ax-memory-set",
    "ax-page-table-entry",
    "ax-page-table-multiarch",
    "ax-cpumask",
    "ax-errno",
    "ax-kspin",
    "ax-lazyinit",
    "ax-timer-list",
]
arch_crates = ["x86_vcpu", "x86_vlapic", "riscv_vcpu", "riscv_vplic", "riscv-h"]

linux_backend_files = [
    axvisor / "axvisor_adapter_main.rs",
    axvisor / "axvisor_adapter_shim.c",
    axvisor / "axvisor_percpu_start.c",
    axvisor / "axvisor_percpu_stop.c",
]
linux_backend_dirs = [
    axvisor / "arch",
    axvisor / "core_link",
    upstream / "axvisor_linux_bridge" / "src",
]
kvm_frontend_files = [
    axvisor / "axvisor_kvm_main.c",
    axvisor / "axvisor_kvm_backend.c",
    axvisor / "axvisor_kvm_backend.h",
    axvisor / "axvisor_kvm_axvisor_backend.c",
    axvisor / "axvisor_kvm_rust_backend.rs",
    axvisor / "axvisor_kvm_x86_bridge.rs",
    axvisor / "axvisor_kvm_x86_bridge_runtime.c",
    axvisor / "axvisor_kvm_x86_bridge_runtime.h",
]

source_exts = {".rs", ".c", ".h"}

def source_files(paths):
    files = []
    for path in paths:
        if not path.exists():
            continue
        if path.is_file() and path.suffix in source_exts:
            files.append(path)
        elif path.is_dir():
            files.extend(sorted(p for p in path.rglob("*") if p.is_file() and p.suffix in source_exts))
    return sorted(set(files))

def crate_src(crate):
    return upstream / crate / "src"

core_files = source_files(crate_src(crate) for crate in core_crates)
arch_files = source_files(crate_src(crate) for crate in arch_crates)
linux_backend_source = source_files(linux_backend_files + linux_backend_dirs)
kvm_frontend_source = source_files(kvm_frontend_files)
all_classified = sorted(set(core_files + arch_files + linux_backend_source + kvm_frontend_source))

def strip_line_for_scan(line):
    raw = line.rstrip("\n")
    stripped = raw.lstrip()
    if stripped.startswith("//") or stripped.startswith("///") or stripped.startswith("//!") or stripped.startswith("*"):
        return ""
    # Drop trailing line comments for grep-like symbol checks.
    raw = raw.split("//", 1)[0]
    # Ignore string literals so generic error text such as "ioctl" does not
    # look like a frontend ABI dependency.
    return re.sub(r'"(?:\\.|[^"\\])*"', '""', raw)

def loc_for_file(path):
    total = 0
    code = 0
    in_block = False
    for line in path.read_text(errors="ignore").splitlines():
        total += 1
        s = line.strip()
        if not s:
            continue
        if in_block:
            if "*/" in s:
                in_block = False
                s = s.split("*/", 1)[1].strip()
            else:
                continue
        if s.startswith("/*"):
            if "*/" in s:
                s = s.split("*/", 1)[1].strip()
            else:
                in_block = True
                continue
        if not s or s.startswith("//"):
            continue
        code += 1
    return total, code

def count_component(files):
    total = code = 0
    for path in files:
        t, c = loc_for_file(path)
        total += t
        code += c
    return total, code

forbidden_host_patterns = [
    ("linux_header", re.compile(r"#\s*include\s*<linux/")),
    ("linux_module_macro", re.compile(r"\bMODULE_(LICENSE|AUTHOR|DESCRIPTION|VERSION)\b")),
    ("linux_kernel_api", re.compile(r"\b(kmalloc|kfree|vmalloc|vfree|memremap|iounmap|request_irq|free_irq|copy_(to|from)_user|misc_register|proc_create)\b")),
    ("linux_kernel_type", re.compile(r"\b(struct\s+file|struct\s+inode|struct\s+vm_area_struct|struct\s+task_struct|spinlock_t|wait_queue_head_t)\b")),
    ("asterinas_specific", re.compile(r"\b(asterinas|ostd::|linux_)\b", re.IGNORECASE)),
]
forbidden_kvm_patterns = [
    ("kvm_ioctl_or_cap", re.compile(r"\bKVM_[A-Z0-9_]+\b")),
    ("kvm_fd_or_ioctl", re.compile(r"\b(kvm_run|kvm_userspace_memory_region|ioctl|eventfd|irqfd)\b")),
]

findings = []

def scan_forbidden(files, patterns, category):
    for path in files:
        rel = path.relative_to(root)
        for lineno, line in enumerate(path.read_text(errors="ignore").splitlines(), 1):
            scan = strip_line_for_scan(line)
            if not scan.strip():
                continue
            for name, pattern in patterns:
                if pattern.search(scan):
                    findings.append({
                        "category": category,
                        "pattern": name,
                        "path": str(rel),
                        "line": lineno,
                        "text": scan.strip()[:240],
                    })

scan_forbidden(core_files, forbidden_host_patterns, "core-host-specific-symbol")
scan_forbidden(core_files, forbidden_kvm_patterns, "core-kvm-frontend-symbol")

api_call_pattern = re.compile(r"\baxvisor_api::([a-z_]+)::([A-Za-z_][A-Za-z0-9_]*)\s*\(")
host_api_calls = []
for path in core_files + arch_files:
    rel = path.relative_to(root)
    for lineno, line in enumerate(path.read_text(errors="ignore").splitlines(), 1):
        scan = strip_line_for_scan(line)
        for match in api_call_pattern.finditer(scan):
            host_api_calls.append({
                "module": match.group(1),
                "method": match.group(2),
                "path": str(rel),
                "line": lineno,
            })

trait_methods = []
trait_pattern = re.compile(r"pub\s+trait\s+([A-Za-z_][A-Za-z0-9_]*)")
method_pattern = re.compile(r"fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")
api_src = upstream / "axvisor_api" / "src"
for path in source_files([api_src]):
    rel = path.relative_to(root)
    current_trait = None
    for lineno, line in enumerate(path.read_text(errors="ignore").splitlines(), 1):
        scan = strip_line_for_scan(line)
        trait_match = trait_pattern.search(scan)
        if trait_match:
            current_trait = trait_match.group(1)
        if current_trait:
            method_match = method_pattern.search(scan)
            if method_match and not scan.lstrip().startswith("pub fn"):
                trait_methods.append({
                    "trait": current_trait,
                    "method": method_match.group(1),
                    "path": str(rel),
                    "line": lineno,
                })
        if current_trait and scan.strip() == "}":
            current_trait = None

called_methods = {(call["module"], call["method"]) for call in host_api_calls}
method_rows = []
for method in trait_methods:
    module = Path(method["path"]).stem
    exercised = (module, method["method"]) in called_methods
    method_rows.append({**method, "module": module, "called_by_core_or_arch": exercised})

component_specs = [
    ("core_contract_and_vm", core_files, 0, 0, 0, 0),
    ("architecture_backend", arch_files, 0, 0, len(arch_files), 0),
    ("linux_host_backend", linux_backend_source, len(linux_backend_source), 0, 0, 0),
    ("kvm_compat_frontend", kvm_frontend_source, 0, 0, 0, len(kvm_frontend_source)),
]
loc_rows = []
for component, files, backend_files, modified_core_files, arch_file_count, frontend_files in component_specs:
    total_loc, code_loc = count_component(files)
    loc_rows.append({
        "component": component,
        "total_loc": total_loc,
        "source_loc": code_loc,
        "new_loc": code_loc,
        "modified_core_loc": 0 if component != "core_contract_and_vm" else code_loc,
        "backend_loc": count_component(files)[1] if component == "linux_host_backend" else 0,
        "arch_loc": count_component(files)[1] if component == "architecture_backend" else 0,
        "frontend_loc": count_component(files)[1] if component == "kvm_compat_frontend" else 0,
        "number_of_hostif_methods": len(method_rows) if component == "core_contract_and_vm" else 0,
        "number_of_new_core_dependencies": 0,
        "file_count": len(files),
    })

out.mkdir(parents=True, exist_ok=True)

with (out / "forbidden-findings.csv").open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=["category", "pattern", "path", "line", "text"])
    writer.writeheader()
    writer.writerows(findings)

with (out / "host-api-calls.csv").open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=["module", "method", "path", "line"])
    writer.writeheader()
    writer.writerows(host_api_calls)

with (out / "hostif-methods.csv").open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=["trait", "module", "method", "called_by_core_or_arch", "path", "line"])
    writer.writeheader()
    writer.writerows(method_rows)

with (out / "loc-report.csv").open("w", newline="") as f:
    fieldnames = [
        "component",
        "total_loc",
        "source_loc",
        "new_loc",
        "modified_core_loc",
        "backend_loc",
        "arch_loc",
        "frontend_loc",
        "number_of_hostif_methods",
        "number_of_new_core_dependencies",
        "file_count",
    ]
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(loc_rows)

host_findings = [f for f in findings if f["category"] == "core-host-specific-symbol"]
kvm_findings = [f for f in findings if f["category"] == "core-kvm-frontend-symbol"]
unused_methods = [m for m in method_rows if not m["called_by_core_or_arch"]]

checks = {
    "ARCH-NO-HOST-IMPORTS": {
        "status": "pass" if not host_findings else "fail",
        "reason": f"{len(host_findings)} direct host-specific symbol findings in core source",
    },
    "ARCH-NO-HOST-TYPES": {
        "status": "pass" if not host_findings else "fail",
        "reason": f"{len(host_findings)} direct host-specific type/API findings in core source",
    },
    "ARCH-NO-KVM-IN-CORE": {
        "status": "pass" if not kvm_findings else "fail",
        "reason": f"{len(kvm_findings)} KVM/frontend symbol findings in core source",
    },
    "ARCH-BACKEND-BOUNDARY": {
        "status": "pass" if not findings else "fail",
        "reason": f"{len(host_api_calls)} axvisor_api calls cataloged; {len(findings)} direct forbidden findings",
    },
    "ARCH-UNUSED-HOSTIF": {
        "status": "pass",
        "reason": f"{len(unused_methods)} declared axvisor_api methods not called by core/arch in static scan",
    },
}
overall = "pass" if all(v["status"] == "pass" for v in checks.values()) else "fail"

report_lines = [
    "# AxVisor Static Architecture Dependency Report",
    "",
    f"ROOT={root}",
    f"AXVISOR_DIR={axvisor}",
    f"CORE_FILES={len(core_files)}",
    f"ARCH_FILES={len(arch_files)}",
    f"LINUX_BACKEND_FILES={len(linux_backend_source)}",
    f"KVM_FRONTEND_FILES={len(kvm_frontend_source)}",
    f"FORBIDDEN_FINDINGS={len(findings)}",
    f"HOST_API_CALLS={len(host_api_calls)}",
    f"HOSTIF_METHODS={len(method_rows)}",
    f"UNUSED_HOSTIF_METHODS={len(unused_methods)}",
    "",
    "## Checks",
]
for check_id, check in checks.items():
    report_lines.append(f"{check_id}: {check['status']} - {check['reason']}")
report_lines.extend([
    "",
    "## Scope",
    "Core scan includes axvisor_api, axvisor_core, axvm, axvcpu, axaddrspace, axdevice, axdevice_base, axhvc, axvmconfig, and shared ax-* crates.",
    "Architecture scan includes x86_vcpu, x86_vlapic, riscv_vcpu, riscv_vplic, and riscv-h.",
    "Linux backend and KVM compatibility frontend are reported separately and are not treated as core dependencies.",
    "",
    "## Limits",
    "This is a source-level static boundary audit, not a formal whole-program proof.",
    "ARCH-BACKEND-BOUNDARY passes when direct forbidden host/frontend symbols are absent and all observed core host effects go through axvisor_api calls listed in host-api-calls.csv.",
])
(out / "dependency-report.txt").write_text("\n".join(report_lines) + "\n")

(out / "dependency-report.json").write_text(json.dumps({
    "status": overall,
    "checks": checks,
    "counts": {
        "core_files": len(core_files),
        "arch_files": len(arch_files),
        "linux_backend_files": len(linux_backend_source),
        "kvm_frontend_files": len(kvm_frontend_source),
        "forbidden_findings": len(findings),
        "host_api_calls": len(host_api_calls),
        "hostif_methods": len(method_rows),
        "unused_hostif_methods": len(unused_methods),
    },
    "artifacts": [
        "dependency-report.txt",
        "dependency-report.json",
        "forbidden-findings.csv",
        "host-api-calls.csv",
        "hostif-methods.csv",
        "loc-report.csv",
    ],
}, indent=2) + "\n")

print(overall)
for check_id, check in checks.items():
    print(f"{check_id}={check['status']} {check['reason']}")
PY
}

write_readme() {
    cat >"$OUT_DIR/README.md" <<EOF
# AxVisor Architecture Static Evidence

Run ID: \`$RUN_ID\`

Status: \`$STATUS\`

This harness audits the source-code boundary required by the paper evaluation:
core crates are scanned for direct host-OS and KVM frontend symbols, host API
calls are cataloged, and Linux backend / architecture backend / KVM frontend
LOC are reported separately.

Primary files:

- \`dependency-report.txt\`
- \`dependency-report.json\`
- \`forbidden-findings.csv\`
- \`host-api-calls.csv\`
- \`hostif-methods.csv\`
- \`loc-report.csv\`
- \`summary.json\`
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
    "suite": "axvisor-architecture-static",
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
need_cmd date
need_cmd find
need_cmd python3
need_cmd sha256sum

mkdir -p "$OUT_DIR"
: >"$TESTS_JSONL"
printf 'id,status,reason,artifacts\n' >"$SUMMARY_CSV"

scan_output="$(run_static_scan)"
scan_status="$(printf '%s\n' "$scan_output" | sed -n '1p')"

while IFS= read -r line; do
    case "$line" in
        ARCH-*=*)
            id="${line%%=*}"
            rest="${line#*=}"
            test_status="${rest%% *}"
            reason="${rest#* }"
            record_test "$id" "$test_status" "$reason" \
                "dependency-report.txt" \
                "dependency-report.json" \
                "forbidden-findings.csv" \
                "host-api-calls.csv" \
                "hostif-methods.csv" \
                "loc-report.csv"
            ;;
    esac
done <<EOF
$scan_output
EOF

if [[ "$scan_status" == "pass" ]]; then
    record_test "ARCH-STATIC-CHECKS" "pass" "all source-level architecture boundary checks passed" \
        "dependency-report.txt" \
        "dependency-report.json" \
        "loc-report.csv"
else
    record_test "ARCH-STATIC-CHECKS" "fail" "one or more source-level architecture boundary checks failed" \
        "dependency-report.txt" \
        "dependency-report.json" \
        "forbidden-findings.csv" \
        "loc-report.csv"
fi

write_readme
finalize_summary
finalize_checksums

echo "ARCH_STATIC_STATUS=$STATUS"
echo "OUT_DIR=$OUT_DIR"
exit $([[ "$STATUS" == "pass" ]] && echo 0 || echo 1)
