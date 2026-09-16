#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
fh_require_nested_tcg_qemu

"$FH_REPO_ROOT/scripts/zephyr/build.sh" linux
run_log="$FH_ARTIFACTS/linux-guest-tcg.log"
FH_QEMU_MEMORY_MB=128 FH_QEMU_TIMEOUT="${FH_LINUX_TIMEOUT:-180}" \
	FH_QEMU_DEBUG_EXIT=0 \
	fh_run_qemu "$FH_BUILD_ROOT/linux/zephyr/zephyr.elf" "$run_log" max \
	"tcg,thread=multi"

grep -q 'Linux version ' "$run_log"
grep -q 'FH_LINUX_GUEST userspace-entered' "$run_log"
grep -q 'FH_LINUX_GUEST uname=Linux ' "$run_log"
grep -q 'FH_LINUX_GUEST pid=1 result=PASS' "$run_log"
grep -q 'FH_LINUX_GUEST requesting-system-down' "$run_log"
grep -q 'VM\[1\] run VCpu\[0\] SystemDown' "$run_log"
grep -q 'VM\[1\] state changed to Stopped' "$run_log"
grep -q 'VM\[1\] VCpu resources cleaned up' "$run_log"
grep -q 'All cores have disabled hardware virtualization support' "$run_log"
grep -q 'FH_RESULT core-static result=PASS' "$run_log"
if grep -Eq 'ASSERTION FAIL|Fatal error|Failed to queue interrupt|failed to quiesce' "$run_log"; then
	echo "Linux guest reached a dirty teardown state" >&2
	exit 1
fi
echo "Zephyr-hosted FreeHypervisor Linux guest PASS"
