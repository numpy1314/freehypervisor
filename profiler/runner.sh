#!/usr/bin/env bash
#
# runner.sh — HHAL Host Service Dependency Profiler: Data Collection
#
# Starts a minimal QEMU VM under strace, annotates VM lifecycle phases,
# and produces raw event data for analyze.py.
#
# Usage:
#   sudo ./runner.sh [output_dir]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# === Configuration ===
OUTDIR="${1:-${PROJECT_DIR}/data}"
STRACE_DIR="${OUTDIR}/strace"
PHASES_FILE="${OUTDIR}/phases.tsv"

QEMU_BIN="/home/bullet1517/qemu-9.2.4/build/qemu-system-x86_64"
VMLINUX_BOOT="/boot/vmlinuz-$(uname -r)"
VMLINUZ="${OUTDIR}/vmlinuz"
# Use minimal busybox initrd (built by build_initrd.sh) instead of host initrd
INITRD="${OUTDIR}/minimal_initrd.cpio.gz"
INITRD_SRC="${SCRIPT_DIR}/minimal_initrd.cpio.gz"
DISK="${OUTDIR}/disk.raw"
DISK_SIZE="64M"

VM_MEMORY="512"
VM_SMP="1"

# Total run time (seconds). The VM runs this long before we kill it.
STEADY_IDLE_DURATION=10
STEADY_IO_DURATION=10

mkdir -p "${OUTDIR}" "${STRACE_DIR}"

echo "=== HHAL Profiler: runner.sh ==="
echo "Output dir: ${OUTDIR}"
echo "QEMU:       ${QEMU_BIN}"
echo ""

# Verify dependencies
for cmd in strace "${QEMU_BIN}"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "ERROR: ${cmd} not found" >&2
        exit 1
    fi
done

# Copy kernel to output dir if not already there (needs readable source)
if [[ ! -f "${VMLINUZ}" ]]; then
    echo "Copying kernel to ${VMLINUZ}..."
    cp "${VMLINUX_BOOT}" "${VMLINUZ}" 2>/dev/null || {
        echo "ERROR: Cannot read ${VMLINUX_BOOT} (permission denied)."
        echo "  Please run:"
        echo "    sudo cp ${VMLINUX_BOOT} ${VMLINUZ} && sudo chmod 644 ${VMLINUZ}"
        exit 1
    }
    chmod 644 "${VMLINUZ}"
fi

# Copy minimal initrd if not already there
if [[ ! -f "${INITRD}" ]]; then
    if [[ -f "${INITRD_SRC}" ]]; then
        echo "Copying minimal initrd to ${INITRD}..."
        cp "${INITRD_SRC}" "${INITRD}"
    else
        echo "ERROR: Minimal initrd not found at ${INITRD_SRC}"
        echo "  Please build it first: cd /tmp && mkdir -p minimal_initrd/{bin,sbin,proc,sys,dev,etc,tmp,root}"
        echo "  Copy busybox, create init script, build cpio archive."
        exit 1
    fi
fi

echo "Kernel:     ${VMLINUZ}"
echo "Initrd:     ${INITRD}"
echo ""

# Create a small disk image if not exists
if [[ ! -f "${DISK}" ]]; then
    echo "Creating ${DISK_SIZE} disk image..."
    qemu-img create -f raw "${DISK}" "${DISK_SIZE}"
fi

# Clean previous run
rm -f "${STRACE_DIR}/qemu."* "${PHASES_FILE}"

# === Phase file header ===
echo -e "phase\ttimestamp" > "${PHASES_FILE}"

# === Launch QEMU under strace ===
echo ""
echo "Starting QEMU under strace..."
echo "  Phase: VM_CREATE begins at QEMU launch"

QEMU_CMD=(
    "${QEMU_BIN}"
    -enable-kvm
    -m "${VM_MEMORY}"
    -smp "${VM_SMP}"
    -nographic
    -kernel "${VMLINUZ}"
    -initrd "${INITRD}"
    -append "console=ttyS0 panic=1 quiet"
    -drive file="${DISK}",format=raw,if=virtio
    -no-reboot
)

# Record VM_CREATE start
VM_CREATE_TS=$(date +%s.%N)
echo -e "VM_CREATE\t${VM_CREATE_TS}" >> "${PHASES_FILE}"

# strace flags:
#   -ff       : follow forks (each thread gets its own file)
#   -tt       : print timestamps with microseconds
#   -T        : print time spent in syscall
#   -o        : output prefix
#   -s 256    : increase string size limit
#   No -e trace= filter: capture ALL syscalls for complete coverage
strace -ff -tt -T -s 256 \
    -o "${STRACE_DIR}/qemu" \
    "${QEMU_CMD[@]}" &
QEMU_PID=$!

echo "QEMU PID: ${QEMU_PID}"

# Wait for first KVM_RUN to indicate VM_BOOT
echo "Waiting for first KVM_RUN (VM_BOOT)..."
BOOT_DETECTED=0
BOOT_WAIT=30  # max seconds to wait
ELAPSED=0
while [[ ${ELAPSED} -lt ${BOOT_WAIT} ]]; do
    # Check if QEMU is still alive
    if ! kill -0 "${QEMU_PID}" 2>/dev/null; then
        echo "QEMU exited before boot detection. Checking if it completed quickly..."
        break
    fi

    # Grep for KVM_RUN in strace output files
    if grep -rl "KVM_RUN\|ioctl.*0xae80\|ioctl.*0xAE80" "${STRACE_DIR}/" 2>/dev/null | head -1 | xargs grep -m1 "KVM_RUN\|0xae80\|0xAE80" 2>/dev/null; then
        BOOT_DETECTED=1
        VM_BOOT_TS=$(date +%s.%N)
        echo -e "VM_BOOT\t${VM_BOOT_TS}" >> "${PHASES_FILE}"
        echo "  Phase: VM_BOOT at ${VM_BOOT_TS}"
        break
    fi

    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

if [[ ${BOOT_DETECTED} -eq 0 ]]; then
    echo "WARNING: Could not detect VM_BOOT (no KVM_RUN found in ${BOOT_WAIT}s)."
    echo "  Recording approximate boot time."
    VM_BOOT_TS=$(date +%s.%N)
    echo -e "VM_BOOT\t${VM_BOOT_TS}" >> "${PHASES_FILE}"
fi

# Wait for boot to settle → STEADY_IDLE
echo "Waiting ${STEADY_IDLE_DURATION}s for guest to reach steady idle..."
sleep "${STEADY_IDLE_DURATION}"
STEADY_IDLE_TS=$(date +%s.%N)
echo -e "STEADY_IDLE\t${STEADY_IDLE_TS}" >> "${PHASES_FILE}"
echo "  Phase: STEADY_IDLE at ${STEADY_IDLE_TS}"

# Skip STEADY_IO for v1 (no workload injection yet)
STEADY_IO_TS=$(date +%s.%N)
echo -e "STEADY_IO\t${STEADY_IO_TS}" >> "${PHASES_FILE}"

# Wait then kill
sleep "${STEADY_IO_DURATION}"

echo "Terminating QEMU..."
# Kill the entire process group (strace + QEMU + all threads)
# QEMU_PID points to strace; kill its process tree
kill -- -"${QEMU_PID}" 2>/dev/null || kill "${QEMU_PID}" 2>/dev/null || true
sleep 1
# Force kill if still running
if kill -0 "${QEMU_PID}" 2>/dev/null; then
    echo "  QEMU did not exit, sending SIGKILL..."
    kill -9 -- -"${QEMU_PID}" 2>/dev/null || kill -9 "${QEMU_PID}" 2>/dev/null || true
fi
wait "${QEMU_PID}" 2>/dev/null || true

VM_DESTROY_TS=$(date +%s.%N)
echo -e "VM_DESTROY\t${VM_DESTROY_TS}" >> "${PHASES_FILE}"
echo "  Phase: VM_DESTROY at ${VM_DESTROY_TS}"

echo ""
echo "=== Collection complete ==="
echo "Strace files:"
ls -la "${STRACE_DIR}/"
echo ""
echo "Phase file:"
cat "${PHASES_FILE}"
echo ""
echo "Next step: python3 ${SCRIPT_DIR}/analyze.py ${OUTDIR}"
