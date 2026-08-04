#!/usr/bin/env bash
# Run gVisor (runsc) with --platform=kvm on top of our axvisor_kvm.ko shim,
# inside an L1 QEMU host (mirrors verify-axvisor-kvm-x86-firecracker-run.sh).
# Purpose: exercise the shim's KVM-API surface with a second real userspace VMM.
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-/tmp/axvisor-kvm-x86-firecracker-init-build}"
RUN_DIR="${RUN_DIR:-$(mktemp -d /tmp/axvisor-kvm-x86-gvisor-run.XXXXXX)}"
QEMU_BIN="${QEMU_BIN:-/home/bullet1517/qemu-9.2.4/build/qemu-system-x86_64}"
QEMU_ACCEL="${QEMU_ACCEL:-kvm}"
QEMU_CPU="${QEMU_CPU:-}"
QEMU_MEM="${QEMU_MEM:-4096M}"
QEMU_SMP="${QEMU_SMP:-4}"
TIMEOUT_SECS="${TIMEOUT_SECS:-240}"
POLL_SECS="${POLL_SECS:-1}"
SKIP_BUILD="${SKIP_BUILD:-0}"
BUSYBOX="${BUSYBOX:-/usr/bin/busybox}"
RUNSC_BIN="${RUNSC_BIN:-/tmp/gvisor-bin/runsc}"
AXVISOR_KVM_MODULE_ARGS="${AXVISOR_KVM_MODULE_ARGS:-}"

KO_PATH="$BUILD_DIR/drivers/virt/axvisor/axvisor_kvm.ko"
HOST_KERNEL_IMAGE="$BUILD_DIR/arch/x86/boot/bzImage"
HOST_INITRAMFS_DIR="$RUN_DIR/host-initramfs"
HOST_INITRAMFS_IMG="$RUN_DIR/host-initramfs.cpio.gz"
QEMU_LOG="$RUN_DIR/qemu.log"
QEMU_PID=""

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }; }
need_file() { [[ -f "$1" ]] || { echo "required file not found: $1" >&2; exit 1; }; }

cleanup() {
    if [[ -n "$QEMU_PID" ]]; then
        kill "$QEMU_PID" >/dev/null 2>&1 || true
        wait "$QEMU_PID" 2>/dev/null || true
        QEMU_PID=""
    fi
}

build_kernel_and_module() {
    if [[ "$SKIP_BUILD" == "1" ]]; then
        echo "[verify] skip build"
    else
        echo "[verify] build x86_64 host kernel image and axvisor_kvm.ko"
        BUILD_DIR="$BUILD_DIR" \
        AXVISOR_KVM_BACKEND=1 \
        AXVISOR_KVM_X86_BRIDGE=1 \
        AXVISOR_KVM_BUILD_BZIMAGE=1 \
            bash "$ROOT_DIR/tools/build-axvisor-kvm-x86-module.sh"
    fi
    need_file "$HOST_KERNEL_IMAGE"
    need_file "$KO_PATH"
    need_file "$RUNSC_BIN"
    need_file "$BUSYBOX"
}

prepare_host_initramfs() {
    local applet

    echo "[verify] prepare Linux host initramfs (gvisor): $HOST_INITRAMFS_IMG"
    rm -rf "$HOST_INITRAMFS_DIR"
    mkdir -p "$HOST_INITRAMFS_DIR/bin" "$HOST_INITRAMFS_DIR/dev" \
        "$HOST_INITRAMFS_DIR/proc" "$HOST_INITRAMFS_DIR/root" \
        "$HOST_INITRAMFS_DIR/sys" "$HOST_INITRAMFS_DIR/tmp"

    cp "$BUSYBOX" "$HOST_INITRAMFS_DIR/bin/busybox"
    chmod +x "$HOST_INITRAMFS_DIR/bin/busybox"
    for applet in sh mount umount uname dmesg insmod ls sleep mkdir cat grep sync \
        poweroff reboot tail head kill ps env cp ln chmod mknod; do
        ln -s busybox "$HOST_INITRAMFS_DIR/bin/$applet"
    done

    cp "$KO_PATH" "$HOST_INITRAMFS_DIR/root/axvisor_kvm.ko"
    cp "$RUNSC_BIN" "$HOST_INITRAMFS_DIR/root/runsc"
    chmod +x "$HOST_INITRAMFS_DIR/root/runsc"

    # Pre-bake a minimal OCI bundle so runsc does not depend on the host rootfs.
    local bundle="$HOST_INITRAMFS_DIR/root/bundle"
    mkdir -p "$bundle/rootfs/bin" "$bundle/rootfs/dev" \
        "$bundle/rootfs/proc" "$bundle/rootfs/sys"
    cp "$BUSYBOX" "$bundle/rootfs/bin/busybox"
    chmod +x "$bundle/rootfs/bin/busybox"
    for applet in sh echo uname cat sleep; do
        ln -s busybox "$bundle/rootfs/bin/$applet"
    done
    cat >"$bundle/rootfs/entry.sh" <<'EOF'
#!/bin/sh
echo "GVISOR_GUEST_PASS=1"
echo "GVISOR_GUEST_STAGE=entry"
uname -a
echo "GVISOR_GUEST_UNAME_DONE=1"
echo "GVISOR_GUEST_STAGE=idle"
# Exit cleanly so runsc tears down and the host loop can observe success.
EOF
    chmod +x "$bundle/rootfs/entry.sh"
    cat >"$bundle/config.json" <<'EOF'
{
  "ociVersion": "1.0.0",
  "process": {
    "terminal": false,
    "user": {"uid": 0, "gid": 0},
    "args": ["/bin/sh", "/entry.sh"],
    "env": ["PATH=/bin", "HOME=/"],
    "cwd": "/",
    "capabilities": {
      "bounding": ["CAP_SYS_ADMIN"],
      "effective": ["CAP_SYS_ADMIN"],
      "permitted": ["CAP_SYS_ADMIN"]
    },
    "rlimits": []
  },
  "root": {"path": "rootfs", "readonly": false},
  "hostname": "gvisor-probe",
  "mounts": [
    {"destination": "/proc", "type": "proc", "source": "proc"},
    {"destination": "/dev", "type": "tmpfs", "source": "tmpfs"}
  ],
  "linux": {
    "namespaces": [
      {"type": "pid"},
      {"type": "mount"},
      {"type": "ipc"},
      {"type": "uts"}
    ]
  }
}
EOF

    cat >"$HOST_INITRAMFS_DIR/init" <<EOF
#!/bin/sh
set -eu
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
AXVISOR_KVM_MODULE_ARGS="${AXVISOR_KVM_MODULE_ARGS}"
EOF
    cat >>"$HOST_INITRAMFS_DIR/init" <<'EOF'

finish() {
    sync || true
    poweroff -f || reboot -f || sleep 3600
}

dump_context() {
    echo "[guest-host] runsc debug log tail"
    tail -n 400 /root/runsc-debug.log 2>/dev/null || true
    echo "[guest-host] runsc stdout/stderr"
    cat /root/runsc-run.log 2>/dev/null || true
    echo "[guest-host] dmesg tail"
    dmesg | tail -n 200 || true
}

fail() {
    echo "AXVISOR_KVM_GVISOR_RUN_FAIL=$1"
    dump_context
    finish
}

mount -t proc proc /proc || true
mount -t sysfs sysfs /sys || true
mount -t devtmpfs devtmpfs /dev || true
mkdir -p /dev /proc /sys /tmp /root

echo "[guest-host] uname -a"
uname -a || true

echo "[guest-host] insmod axvisor_kvm.ko dev_name=kvm ${AXVISOR_KVM_MODULE_ARGS}"
if ! insmod /root/axvisor_kvm.ko dev_name=kvm ${AXVISOR_KVM_MODULE_ARGS}; then
    fail "insmod"
fi

if [ ! -e /dev/kvm ]; then
    ls -l /dev || true
    fail "missing-dev-kvm"
fi
ls -l /dev/kvm || true

# runsc needs /sys/fs/cgroup for some checks; we pass --ignore-cgroups.
# Running as root in initramfs => no --rootless needed (avoids userns/newuidmap).
echo "[guest-host] run gVisor runsc --platform=kvm run"
: >/root/runsc-run.log
: >/root/runsc-debug.log
cd /root/bundle
/root/runsc \
    --platform=kvm \
    --network=none \
    --ignore-cgroups \
    --directfs=false \
    --debug \
    --debug-log=/root/runsc-debug.log \
    --root=/tmp/runsc-root \
    run gvisor-probe \
    >/root/runsc-run.log 2>&1 &
rc_pid="$!"

i=0
while [ "$i" -lt 200 ]; do
    if grep -q "GVISOR_GUEST_PASS=1" /root/runsc-run.log 2>/dev/null &&
       grep -q "GVISOR_GUEST_UNAME_DONE=1" /root/runsc-run.log 2>/dev/null; then
        echo "AXVISOR_KVM_GVISOR_RUN_QEMU_PASS=1"
        echo "[guest-host] gvisor run output"
        cat /root/runsc-run.log || true
        dump_context
        kill "$rc_pid" >/dev/null 2>&1 || true
        finish
    fi
    if ! kill -0 "$rc_pid" >/dev/null 2>&1; then
        wait "$rc_pid" || true
        if grep -q "GVISOR_GUEST_PASS=1" /root/runsc-run.log 2>/dev/null; then
            echo "AXVISOR_KVM_GVISOR_RUN_QEMU_PASS=1"
            cat /root/runsc-run.log || true
            dump_context
            finish
        fi
        echo "[guest-host] runsc exited before pass"
        fail "runsc-exited-before-pass"
    fi
    sleep 1
    i=$((i + 1))
    if [ $((i % 15)) -eq 0 ]; then
        echo "[guest-host] progress i=$i run.log tail:"
        tail -n 6 /root/runsc-run.log 2>/dev/null || true
        echo "[guest-host] debug.log kvm/vcpu/error tail:"
        grep -aiE "kvm|vcpu|bluepill|throw|panic|error|unsupported ioctl|ENOTTY|not implemented" /root/runsc-debug.log 2>/dev/null | tail -n 8 || true
    fi
    # Cross-layer stall forensics: once we are clearly stuck (i>=25 ~= 25s in,
    # past the t=22s RCU-stall onset) dump ALL L1-host-CPU backtraces + IPI
    # counters once, so we can see which host CPU is not acking the TLB-flush
    # IPI (the fork/dup_mmap smp_call_function hang). sysrq 'l' = all-CPU NMI
    # backtrace; 'interrupts' snapshot shows per-CPU call-function/resched IPIs.
    if [ "$i" = "25" ]; then
        echo "[guest-host] STALL-FORENSICS: all-CPU backtrace + interrupts"
        echo 1 >/proc/sys/kernel/sysrq 2>/dev/null || true
        echo l >/proc/sysrq-trigger 2>/dev/null || true
        sleep 1
        echo "[guest-host] /proc/interrupts:"
        cat /proc/interrupts 2>/dev/null || true
        echo "[guest-host] runsc-debug kvm/bluepill tail:"
        grep -aiE "kvm|bluepill|vcpu|halt|sigp|clone|fork" /root/runsc-debug.log 2>/dev/null | tail -n 20 || true

        # gvisor USERSPACE forensics (task#101): the shim RIP handling is proven
        # correct (VMCS guest RIP progresses 60+ addrs); the wall is now gvisor
        # sentry going to futex_wait AFTER real forward progress and no longer
        # issuing KVM_RUN. Dump the sentry's own goroutine stacks and per-TID
        # host state so we can see WHERE it is blocked: waitUntilNot/bounce
        # (=> signal/IRQ-window semantic), Context.Switch/bluepillHandler
        # (=> KVM_RUN exit semantic), or Task.Block (=> guest futex/timer).
        echo "[guest-host] GV-FORENSICS: runsc debug -stacks"
        /root/runsc --root=/tmp/runsc-root debug -stacks gvisor-probe \
            >/root/runsc-stacks.log 2>&1 || \
            echo "[guest-host] runsc debug -stacks rc=$?"
        # -stacks writes to the sandbox debug log; also capture whatever the
        # debug subcommand itself printed.
        echo "[guest-host] runsc-stacks.log:"
        cat /root/runsc-stacks.log 2>/dev/null || true
        echo "[guest-host] sentry goroutine stacks (from debug.log tail):"
        tail -n 300 /root/runsc-debug.log 2>/dev/null | \
            grep -aA2 -iE "goroutine |waitUntilNot|bluepillHandler|Context.*Switch|Task\).Block|futex|notify|bounce" | \
            tail -n 200 || true

        echo "[guest-host] GV-FORENSICS: per-TID host state of runsc procs"
        for pd in /proc/[0-9]*; do
            pid="${pd#/proc/}"
            comm="$(cat "$pd/comm" 2>/dev/null || true)"
            case "$comm" in
                *runsc*|*sandbox*|*gofer*)
                    echo "== pid=$pid comm=$comm =="
                    for td in "$pd"/task/[0-9]*; do
                        tid="${td#"$pd"/task/}"
                        tcomm="$(cat "$td/comm" 2>/dev/null || true)"
                        twchan="$(cat "$td/wchan" 2>/dev/null || true)"
                        tsysc="$(cat "$td/syscall" 2>/dev/null || true)"
                        tstat="$(cut -d' ' -f3 "$td/stat" 2>/dev/null || true)"
                        echo "  tid=$tid comm=$tcomm state=$tstat wchan=$twchan syscall=$tsysc"
                    done
                    ;;
            esac
        done
    fi
done

kill "$rc_pid" >/dev/null 2>&1 || true
fail "timeout"
EOF
    chmod +x "$HOST_INITRAMFS_DIR/init"

    (
        cd "$HOST_INITRAMFS_DIR"
        find . -print0 | cpio --null -o --format=newc | gzip -9 >"$HOST_INITRAMFS_IMG"
    ) >/dev/null
    need_file "$HOST_INITRAMFS_IMG"
}

launch_qemu() {
    local cpu_arg
    : >"$QEMU_LOG"
    if [[ "$QEMU_ACCEL" == "kvm" && ! -e /dev/kvm ]]; then
        echo "QEMU_ACCEL=kvm requested but /dev/kvm does not exist on this host" >&2
        exit 1
    fi
    if [[ -n "$QEMU_CPU" ]]; then
        cpu_arg="$QEMU_CPU"
    elif [[ "$QEMU_ACCEL" == "kvm" ]]; then
        cpu_arg="host"
    else
        cpu_arg="max"
    fi

    echo "[verify] launch qemu accel=$QEMU_ACCEL cpu=$cpu_arg smp=$QEMU_SMP mem=$QEMU_MEM"
    "$QEMU_BIN" \
        -nodefaults \
        -no-reboot \
        -display none \
        -monitor none \
        -serial "file:$QEMU_LOG" \
        -debugcon "file:$RUN_DIR/debugcon.log" \
        -m "$QEMU_MEM" \
        -smp "$QEMU_SMP" \
        -accel "$QEMU_ACCEL" \
        -cpu "$cpu_arg" \
        -kernel "$HOST_KERNEL_IMAGE" \
        -initrd "$HOST_INITRAMFS_IMG" \
        -append "console=ttyS0 earlyprintk=serial panic=-1 oops=panic nokaslr" &
    QEMU_PID=$!
}

wait_for_result() {
    local deadline
    deadline=$((SECONDS + TIMEOUT_SECS))
    while (( SECONDS < deadline )); do
        if grep -q "^AXVISOR_KVM_GVISOR_RUN_QEMU_PASS=1$" "$QEMU_LOG"; then
            echo "[verify] pass"
            cleanup
            return 0
        fi
        if grep -q "AXVISOR_KVM_GVISOR_RUN_FAIL=" "$QEMU_LOG"; then
            echo "[verify] guest host reported failure" >&2
            tail -n 320 "$QEMU_LOG" >&2 || true
            cleanup
            return 1
        fi
        if [[ -n "$QEMU_PID" ]] && ! kill -0 "$QEMU_PID" >/dev/null 2>&1; then
            wait "$QEMU_PID" || true
            QEMU_PID=""
            if grep -q "^AXVISOR_KVM_GVISOR_RUN_QEMU_PASS=1$" "$QEMU_LOG"; then
                echo "[verify] pass"
                return 0
            fi
            echo "[verify] qemu exited before pass marker" >&2
            tail -n 320 "$QEMU_LOG" >&2 || true
            return 1
        fi
        sleep "$POLL_SECS"
    done
    echo "[verify] timeout after ${TIMEOUT_SECS}s waiting for pass marker" >&2
    tail -n 400 "$QEMU_LOG" >&2 || true
    cleanup
    return 1
}

need_cmd bash
need_cmd cpio
need_cmd find
need_cmd gzip
need_cmd grep
need_cmd ln
need_cmd tail
need_file "$QEMU_BIN"
need_file "$BUSYBOX"
need_file "$RUNSC_BIN"

trap cleanup EXIT
mkdir -p "$RUN_DIR"

build_kernel_and_module
prepare_host_initramfs
launch_qemu
wait_for_result

echo "[verify] run dir: $RUN_DIR"
echo "[verify] qemu log: $QEMU_LOG"
echo "[verify] host kernel image: $HOST_KERNEL_IMAGE"
echo "[verify] module: $KO_PATH"
echo "[verify] runsc: $RUNSC_BIN"
