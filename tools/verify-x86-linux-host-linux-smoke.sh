#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-/tmp/axvisor-adapter-x86-build}"
RUN_DIR="${RUN_DIR:-$(mktemp -d /tmp/axvisor-x86-linux-host-linux-smoke.XXXXXX)}"
QEMU_BIN="${QEMU_BIN:-/home/bullet1517/qemu-9.2.4/build/qemu-system-x86_64}"
QEMU_ACCEL="${QEMU_ACCEL:-kvm}"
QEMU_CPU="${QEMU_CPU:-}"
QEMU_MEM="${QEMU_MEM:-1536M}"
TIMEOUT_SECS="${TIMEOUT_SECS:-240}"
POLL_SECS="${POLL_SECS:-1}"
SKIP_BUILD="${SKIP_BUILD:-0}"
WAIT_FOR_POWEROFF_AFTER_PASS="${WAIT_FOR_POWEROFF_AFTER_PASS:-0}"
WAIT_FOR_SYSTEM_DOWN_AFTER_PASS="${WAIT_FOR_SYSTEM_DOWN_AFTER_PASS:-0}"
X86_GUEST_EXIT_PORT_AFTER_PASS="${X86_GUEST_EXIT_PORT_AFTER_PASS:-0}"
HOST_WAIT_FOR_AXVISOR_SYSTEM_DOWN="${HOST_WAIT_FOR_AXVISOR_SYSTEM_DOWN:-0}"
BUSYBOX="${BUSYBOX:-/usr/bin/busybox}"
AXVISOR_LINUX_VM_CONFIG="${AXVISOR_LINUX_VM_CONFIG:-$ROOT_DIR/tools/x86_64-linux-host-vm.toml}"
BASE_AXVISOR_LINUX_VM_CONFIG="$AXVISOR_LINUX_VM_CONFIG"
GENERATED_AXVISOR_LINUX_VM_CONFIG="$RUN_DIR/x86_64-linux-host-vm.generated.toml"
X86_GUEST_BOOT_MODE="${X86_GUEST_BOOT_MODE:-rootfs}"
GUEST_ROOTFS_IMG="${GUEST_ROOTFS_IMG:-$RUN_DIR/guest-rootfs.img}"
GUEST_ROOTFS_SIZE="${GUEST_ROOTFS_SIZE:-64M}"
GUEST_RESULT_PATH="/axvisor-x86-smoke-result.txt"
GUEST_RESULT_TXT="$RUN_DIR/result.txt"
X86_GUEST_IDENTITY_RAM_BASE="${X86_GUEST_IDENTITY_RAM_BASE:-0x40000000}"
X86_GUEST_IDENTITY_RAM_SIZE="${X86_GUEST_IDENTITY_RAM_SIZE:-128M}"
X86_GUEST_CPU_NUM="${X86_GUEST_CPU_NUM:-1}"
X86_GUEST_PHYS_CPU_IDS="${X86_GUEST_PHYS_CPU_IDS:-auto}"
X86_GUEST_EXTRA_CHECKS="${X86_GUEST_EXTRA_CHECKS:-}"
QEMU_SMP="${QEMU_SMP:-$X86_GUEST_CPU_NUM}"

KO_PATH="$BUILD_DIR/drivers/virt/axvisor/axvisor_adapter.ko"
HOST_KERNEL_IMAGE="$BUILD_DIR/arch/x86/boot/bzImage"
GUEST_KERNEL_IMAGE="${GUEST_KERNEL_IMAGE:-$HOST_KERNEL_IMAGE}"
HOST_INITRAMFS_DIR="$RUN_DIR/host-initramfs"
HOST_INITRAMFS_IMG="$RUN_DIR/host-initramfs.cpio.gz"
GUEST_INITRAMFS_DIR="$RUN_DIR/guest-initramfs"
GUEST_INITRAMFS_IMG="$RUN_DIR/guest-initramfs.cpio.gz"
QEMU_LOG="$RUN_DIR/qemu.log"
QEMU_PID=""

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "missing command: $1" >&2
        exit 1
    }
}

need_file() {
    [[ -f "$1" ]] || {
        echo "required file not found: $1" >&2
        exit 1
    }
}

debugfs_cmds() {
    local image="$1"
    local cmds="$2"

    debugfs -w -f "$cmds" "$image" >/dev/null
}

cleanup() {
    if [[ -n "$QEMU_PID" ]]; then
        kill "$QEMU_PID" >/dev/null 2>&1 || true
        wait "$QEMU_PID" 2>/dev/null || true
        QEMU_PID=""
    fi
}

prepare_guest_rootfs() {
    local rootfs_debugfs_cmds init_template applet exit_port_helper exit_port_source

    echo "[verify] prepare x86 AxVisor guest rootfs: $GUEST_ROOTFS_IMG"
    rm -f "$GUEST_ROOTFS_IMG"
    truncate -s "$GUEST_ROOTFS_SIZE" "$GUEST_ROOTFS_IMG"
    mkfs.ext4 -F "$GUEST_ROOTFS_IMG" >/dev/null

    init_template="$RUN_DIR/guest-rootfs-init.sh"
    cat >"$init_template" <<'EOF'
#!/bin/sh
set -u

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

mount -t devtmpfs devtmpfs /dev || true

emit() {
    msg="$1"
    echo "$msg" || true
    [ -e /dev/kmsg ] && printf '<6>%s\n' "$msg" > /dev/kmsg || true
    [ -e /dev/console ] && printf '%s\n' "$msg" > /dev/console || true
    [ -e /dev/ttyS0 ] && printf '%s\n' "$msg" > /dev/ttyS0 || true
}

emit "AXVISOR_X86_NATIVE_GUEST_STAGE=init-enter"
mount -t proc proc /proc
emit "AXVISOR_X86_NATIVE_GUEST_STAGE=proc-mounted rc=$?"
mount -t sysfs sysfs /sys
emit "AXVISOR_X86_NATIVE_GUEST_STAGE=sys-mounted rc=$?"
mount -t devtmpfs devtmpfs /dev
emit "AXVISOR_X86_NATIVE_GUEST_STAGE=dev-mounted rc=$?"

emit "AXVISOR_X86_NATIVE_GUEST_STAGE=rootfs-boot"
uname -a || true
cat /proc/cmdline || true
if [ -e /dev/vda ]; then
    emit "AXVISOR_X86_NATIVE_GUEST_HAS_DEV_VDA=1"
else
    emit "AXVISOR_X86_NATIVE_GUEST_HAS_DEV_VDA=0"
fi
if [ -e /sys/block/vda ]; then
    emit "AXVISOR_X86_NATIVE_GUEST_HAS_SYS_BLOCK_VDA=1"
else
    emit "AXVISOR_X86_NATIVE_GUEST_HAS_SYS_BLOCK_VDA=0"
fi
ROOT_MOUNT_DEV="$(awk '$2 == "/" { print $1; exit }' /proc/mounts 2>/dev/null || true)"
ROOT_MOUNT_FS="$(awk '$2 == "/" { print $3; exit }' /proc/mounts 2>/dev/null || true)"
CPUINFO_PROCESSOR_COUNT="$(awk 'BEGIN { c = 0 } /^processor[ \t]*:/ { c++ } END { print c + 0 }' /proc/cpuinfo 2>/dev/null || echo 0)"
CPU_ONLINE_LIST="$(cat /sys/devices/system/cpu/online 2>/dev/null || echo unknown)"
CPU_ONLINE_COUNT="$(awk -v list="$CPU_ONLINE_LIST" 'BEGIN {
    total = 0
    n = split(list, parts, ",")
    for (i = 1; i <= n; i++) {
        if (parts[i] ~ /^[0-9]+-[0-9]+$/) {
            split(parts[i], range, "-")
            total += range[2] - range[1] + 1
        } else if (parts[i] ~ /^[0-9]+$/) {
            total += 1
        }
    }
    print total
}' 2>/dev/null || echo 0)"
emit "AXVISOR_X86_NATIVE_GUEST_ROOT_MOUNT_DEV=${ROOT_MOUNT_DEV:-unknown}"
emit "AXVISOR_X86_NATIVE_GUEST_ROOT_MOUNT_FS=${ROOT_MOUNT_FS:-unknown}"
emit "AXVISOR_X86_NATIVE_GUEST_CPUINFO_PROCESSOR_COUNT=${CPUINFO_PROCESSOR_COUNT:-0}"
emit "AXVISOR_X86_NATIVE_GUEST_CPU_ONLINE_LIST=${CPU_ONLINE_LIST:-unknown}"
emit "AXVISOR_X86_NATIVE_GUEST_CPU_ONLINE_COUNT=${CPU_ONLINE_COUNT:-0}"
if echo "axvisor-x86-write-test" > /axvisor-x86-write-test.txt &&
   grep -q "axvisor-x86-write-test" /axvisor-x86-write-test.txt; then
    emit "AXVISOR_X86_NATIVE_GUEST_WRITE_TEST=1"
else
    emit "AXVISOR_X86_NATIVE_GUEST_WRITE_TEST=0"
fi

EXTRA_CHECKS="__X86_GUEST_EXTRA_CHECKS__"
has_extra_check() {
    case ",$EXTRA_CHECKS," in
        *",$1,"*) return 0 ;;
        *) return 1 ;;
    esac
}

TIMER_CHECK=0
TIMER_UPTIME_BEFORE=0
TIMER_UPTIME_AFTER=0
TIMER_DELTA_MS=0
TIMER_MONOTONIC_OK=0
TIMER_SLEEP_WAKE_OK=0
if has_extra_check timer; then
    TIMER_CHECK=1
    emit "AXVISOR_X86_NATIVE_GUEST_STAGE=timer-check-begin"
    TIMER_UPTIME_BEFORE="$(awk '{ print $1 }' /proc/uptime 2>/dev/null || echo 0)"
    sleep 1
    TIMER_UPTIME_AFTER="$(awk '{ print $1 }' /proc/uptime 2>/dev/null || echo 0)"
    TIMER_DELTA_MS="$(awk -v a="$TIMER_UPTIME_BEFORE" -v b="$TIMER_UPTIME_AFTER" 'BEGIN { d = (b - a) * 1000; if (d < 0) d = -1; printf "%d\n", d }' 2>/dev/null || echo 0)"
    TIMER_MONOTONIC_OK="$(awk -v a="$TIMER_UPTIME_BEFORE" -v b="$TIMER_UPTIME_AFTER" 'BEGIN { print (b > a) ? 1 : 0 }' 2>/dev/null || echo 0)"
    TIMER_SLEEP_WAKE_OK="$(awk -v a="$TIMER_UPTIME_BEFORE" -v b="$TIMER_UPTIME_AFTER" 'BEGIN { d = b - a; print (d >= 0.80 && d <= 5.00) ? 1 : 0 }' 2>/dev/null || echo 0)"
    emit "AXVISOR_X86_NATIVE_GUEST_TIMER_UPTIME_BEFORE=$TIMER_UPTIME_BEFORE"
    emit "AXVISOR_X86_NATIVE_GUEST_TIMER_UPTIME_AFTER=$TIMER_UPTIME_AFTER"
    emit "AXVISOR_X86_NATIVE_GUEST_TIMER_DELTA_MS=$TIMER_DELTA_MS"
    emit "AXVISOR_X86_NATIVE_GUEST_TIMER_MONOTONIC_OK=$TIMER_MONOTONIC_OK"
    emit "AXVISOR_X86_NATIVE_GUEST_TIMER_SLEEP_WAKE_OK=$TIMER_SLEEP_WAKE_OK"
    emit "AXVISOR_X86_NATIVE_GUEST_STAGE=timer-check-end"
fi

irq_virtio_count() {
    awk '/virtio/ {
        for (i = 2; i <= NF; i++) {
            if ($i ~ /^[0-9]+$/) {
                total += $i
            }
        }
    } END { print total + 0 }' /proc/interrupts 2>/dev/null || echo 0
}

IRQ_CHECK=0
IRQ_VIRTIO_BEFORE=0
IRQ_VIRTIO_AFTER=0
IRQ_VIRTIO_DELTA=0
IRQ_VIRTIO_DELTA_POSITIVE=0
if has_extra_check irq; then
    IRQ_CHECK=1
    emit "AXVISOR_X86_NATIVE_GUEST_STAGE=irq-check-begin"
    IRQ_VIRTIO_BEFORE="$(irq_virtio_count)"
    i=0
    while [ "$i" -lt 8 ]; do
        echo "axvisor-x86-irq-test-$i" >> /axvisor-x86-irq-test.txt || true
        sync || true
        i=$((i + 1))
    done
    IRQ_VIRTIO_AFTER="$(irq_virtio_count)"
    IRQ_VIRTIO_DELTA="$(awk -v a="$IRQ_VIRTIO_AFTER" -v b="$IRQ_VIRTIO_BEFORE" 'BEGIN { print a - b }' 2>/dev/null || echo 0)"
    IRQ_VIRTIO_DELTA_POSITIVE="$(awk -v d="$IRQ_VIRTIO_DELTA" 'BEGIN { print (d > 0) ? 1 : 0 }' 2>/dev/null || echo 0)"
    emit "AXVISOR_X86_NATIVE_GUEST_IRQ_VIRTIO_BEFORE=$IRQ_VIRTIO_BEFORE"
    emit "AXVISOR_X86_NATIVE_GUEST_IRQ_VIRTIO_AFTER=$IRQ_VIRTIO_AFTER"
    emit "AXVISOR_X86_NATIVE_GUEST_IRQ_VIRTIO_DELTA=$IRQ_VIRTIO_DELTA"
    emit "AXVISOR_X86_NATIVE_GUEST_IRQ_VIRTIO_DELTA_POSITIVE=$IRQ_VIRTIO_DELTA_POSITIVE"
    emit "AXVISOR_X86_NATIVE_GUEST_STAGE=irq-check-end"
fi

MMIO_CHECK=0
MMIO_VIRTIO_RW_ITERATIONS=0
MMIO_VIRTIO_RW_OK=0
if has_extra_check mmio; then
    MMIO_CHECK=1
    emit "AXVISOR_X86_NATIVE_GUEST_STAGE=mmio-check-begin"
    MMIO_VIRTIO_RW_OK=1
    i=0
    while [ "$i" -lt 8 ]; do
        if ! /bin/busybox dd if=/dev/vda of=/dev/null bs=512 count=8 skip="$i" >/dev/null 2>&1; then
            MMIO_VIRTIO_RW_OK=0
        fi
        if ! cat /sys/block/vda/size >/dev/null 2>&1; then
            MMIO_VIRTIO_RW_OK=0
        fi
        if ! echo "axvisor-x86-mmio-test-$i" >> /axvisor-x86-mmio-test.txt; then
            MMIO_VIRTIO_RW_OK=0
        fi
        sync || MMIO_VIRTIO_RW_OK=0
        i=$((i + 1))
    done
    MMIO_VIRTIO_RW_ITERATIONS=8
    emit "AXVISOR_X86_NATIVE_GUEST_MMIO_VIRTIO_RW_ITERATIONS=$MMIO_VIRTIO_RW_ITERATIONS"
    emit "AXVISOR_X86_NATIVE_GUEST_MMIO_VIRTIO_RW_OK=$MMIO_VIRTIO_RW_OK"
    emit "AXVISOR_X86_NATIVE_GUEST_STAGE=mmio-check-end"
fi

emit "AXVISOR_X86_NATIVE_GUEST_STAGE=before-result"
{
    echo "AXVISOR_X86_NATIVE_GUEST_PASS=1"
    printf 'DATE='
    date -Iseconds 2>/dev/null || true
    printf 'UNAME='
    uname -a || true
    printf 'CMDLINE='
    cat /proc/cmdline || true
    echo "HAS_DEV_VDA=$([ -e /dev/vda ] && echo 1 || echo 0)"
    echo "HAS_SYS_BLOCK_VDA=$([ -e /sys/block/vda ] && echo 1 || echo 0)"
    echo "ROOT_MOUNT_DEV=${ROOT_MOUNT_DEV:-unknown}"
    echo "ROOT_MOUNT_FS=${ROOT_MOUNT_FS:-unknown}"
    echo "EXPECTED_GUEST_CPUS=__X86_GUEST_CPU_NUM__"
    echo "CPUINFO_PROCESSOR_COUNT=${CPUINFO_PROCESSOR_COUNT:-0}"
    echo "CPU_ONLINE_LIST=${CPU_ONLINE_LIST:-unknown}"
    echo "CPU_ONLINE_COUNT=${CPU_ONLINE_COUNT:-0}"
    echo "SMOKE_WRITE_TEST=$([ -f /axvisor-x86-write-test.txt ] && grep -q "axvisor-x86-write-test" /axvisor-x86-write-test.txt && echo 1 || echo 0)"
    echo "EXTRA_CHECKS=$EXTRA_CHECKS"
    echo "TIMER_CHECK=$TIMER_CHECK"
    echo "TIMER_UPTIME_BEFORE=$TIMER_UPTIME_BEFORE"
    echo "TIMER_UPTIME_AFTER=$TIMER_UPTIME_AFTER"
    echo "TIMER_DELTA_MS=$TIMER_DELTA_MS"
    echo "TIMER_MONOTONIC_OK=$TIMER_MONOTONIC_OK"
    echo "TIMER_SLEEP_WAKE_OK=$TIMER_SLEEP_WAKE_OK"
    echo "IRQ_CHECK=$IRQ_CHECK"
    echo "IRQ_VIRTIO_BEFORE=$IRQ_VIRTIO_BEFORE"
    echo "IRQ_VIRTIO_AFTER=$IRQ_VIRTIO_AFTER"
    echo "IRQ_VIRTIO_DELTA=$IRQ_VIRTIO_DELTA"
    echo "IRQ_VIRTIO_DELTA_POSITIVE=$IRQ_VIRTIO_DELTA_POSITIVE"
    echo "MMIO_CHECK=$MMIO_CHECK"
    echo "MMIO_VIRTIO_RW_ITERATIONS=$MMIO_VIRTIO_RW_ITERATIONS"
    echo "MMIO_VIRTIO_RW_OK=$MMIO_VIRTIO_RW_OK"
    echo "PROC_MOUNTS_BEGIN"
    cat /proc/mounts || true
    echo "PROC_MOUNTS_END"
} > /axvisor-x86-smoke-result.txt
emit "AXVISOR_X86_NATIVE_GUEST_STAGE=after-result"
emit "AXVISOR_X86_NATIVE_GUEST_STAGE=before-sync"
sync || true
emit "AXVISOR_X86_NATIVE_GUEST_STAGE=after-sync"
emit "AXVISOR_X86_NATIVE_GUEST_PASS=1"
if [ -x /bin/axvisor-exit-port ]; then
    emit "AXVISOR_X86_NATIVE_GUEST_STAGE=before-exit-port"
    /bin/axvisor-exit-port || emit "AXVISOR_X86_NATIVE_GUEST_EXIT_PORT_RC=$?"
    emit "AXVISOR_X86_NATIVE_GUEST_STAGE=after-exit-port"
fi
poweroff -f || reboot -f || sleep 3600
EOF
    sed -i "s/__X86_GUEST_CPU_NUM__/$X86_GUEST_CPU_NUM/g" "$init_template"
    sed -i "s/__X86_GUEST_EXTRA_CHECKS__/$X86_GUEST_EXTRA_CHECKS/g" "$init_template"
    chmod +x "$init_template"

    exit_port_helper=""
    if [[ "$X86_GUEST_EXIT_PORT_AFTER_PASS" == "1" ]]; then
        need_cmd gcc
        exit_port_source="$RUN_DIR/axvisor-exit-port.c"
        exit_port_helper="$RUN_DIR/axvisor-exit-port"
        cat >"$exit_port_source" <<'EOF'
#include <sys/io.h>

int main(void)
{
    if (ioperm(0x604, 2, 1) != 0) {
        return 1;
    }
    asm volatile("outw %0, %1" : : "a"((unsigned short)0x2000), "Nd"((unsigned short)0x604));
    return 0;
}
EOF
        gcc -O2 -static -o "$exit_port_helper" "$exit_port_source"
    fi

    rootfs_debugfs_cmds="$RUN_DIR/guest-rootfs.debugfs"
    {
        echo "mkdir /bin"
        echo "mkdir /dev"
        echo "mkdir /proc"
        echo "mkdir /sys"
        echo "write $BUSYBOX /bin/busybox"
        echo "set_inode_field /bin/busybox mode 0100755"
        if [[ -n "$exit_port_helper" ]]; then
            echo "write $exit_port_helper /bin/axvisor-exit-port"
            echo "set_inode_field /bin/axvisor-exit-port mode 0100755"
        fi
        echo "write $init_template /init"
        echo "set_inode_field /init mode 0100755"
        for applet in sh mount uname cat sync poweroff reboot sleep true date awk grep; do
            echo "symlink /bin/$applet busybox"
        done
    } >"$rootfs_debugfs_cmds"
    debugfs_cmds "$GUEST_ROOTFS_IMG" "$rootfs_debugfs_cmds"
    need_file "$GUEST_ROOTFS_IMG"
}

prepare_guest_initramfs() {
    local applet

    echo "[verify] prepare x86 AxVisor guest initramfs: $GUEST_INITRAMFS_IMG"
    rm -rf "$GUEST_INITRAMFS_DIR"
    mkdir -p "$GUEST_INITRAMFS_DIR/bin" "$GUEST_INITRAMFS_DIR/dev" \
        "$GUEST_INITRAMFS_DIR/proc" "$GUEST_INITRAMFS_DIR/sys"

    cp "$BUSYBOX" "$GUEST_INITRAMFS_DIR/bin/busybox"
    chmod +x "$GUEST_INITRAMFS_DIR/bin/busybox"
    for applet in sh mount uname cat sync poweroff reboot sleep true; do
        ln -s busybox "$GUEST_INITRAMFS_DIR/bin/$applet"
    done

cat >"$GUEST_INITRAMFS_DIR/init" <<'EOF'
#!/bin/sh
set -u

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

mount -t devtmpfs devtmpfs /dev || true

emit() {
    msg="$1"
    echo "$msg" || true
    [ -e /dev/kmsg ] && printf '<6>%s\n' "$msg" > /dev/kmsg || true
    [ -e /dev/console ] && printf '%s\n' "$msg" > /dev/console || true
    [ -e /dev/ttyS0 ] && printf '%s\n' "$msg" > /dev/ttyS0 || true
}

emit "AXVISOR_X86_NATIVE_GUEST_STAGE=init-enter"
mount -t proc proc /proc
emit "AXVISOR_X86_NATIVE_GUEST_STAGE=proc-mounted rc=$?"
mount -t sysfs sysfs /sys
emit "AXVISOR_X86_NATIVE_GUEST_STAGE=sys-mounted rc=$?"
mount -t devtmpfs devtmpfs /dev
emit "AXVISOR_X86_NATIVE_GUEST_STAGE=dev-mounted rc=$?"

emit "AXVISOR_X86_NATIVE_GUEST_STAGE=boot"
uname -a || true
cat /proc/cmdline || true
CPUINFO_PROCESSOR_COUNT="$(awk 'BEGIN { c = 0 } /^processor[ \t]*:/ { c++ } END { print c + 0 }' /proc/cpuinfo 2>/dev/null || echo 0)"
CPU_ONLINE_LIST="$(cat /sys/devices/system/cpu/online 2>/dev/null || echo unknown)"
CPU_ONLINE_COUNT="$(awk -v list="$CPU_ONLINE_LIST" 'BEGIN {
    total = 0
    n = split(list, parts, ",")
    for (i = 1; i <= n; i++) {
        if (parts[i] ~ /^[0-9]+-[0-9]+$/) {
            split(parts[i], range, "-")
            total += range[2] - range[1] + 1
        } else if (parts[i] ~ /^[0-9]+$/) {
            total += 1
        }
    }
    print total
}' 2>/dev/null || echo 0)"
emit "AXVISOR_X86_NATIVE_GUEST_EXPECTED_CPUS=__X86_GUEST_CPU_NUM__"
emit "AXVISOR_X86_NATIVE_GUEST_CPUINFO_PROCESSOR_COUNT=${CPUINFO_PROCESSOR_COUNT:-0}"
emit "AXVISOR_X86_NATIVE_GUEST_CPU_ONLINE_LIST=${CPU_ONLINE_LIST:-unknown}"
emit "AXVISOR_X86_NATIVE_GUEST_CPU_ONLINE_COUNT=${CPU_ONLINE_COUNT:-0}"
emit "AXVISOR_X86_NATIVE_GUEST_PASS=1"
sync || true
poweroff -f || reboot -f || sleep 3600
EOF
    sed -i "s/__X86_GUEST_CPU_NUM__/$X86_GUEST_CPU_NUM/g" "$GUEST_INITRAMFS_DIR/init"
    chmod +x "$GUEST_INITRAMFS_DIR/init"

    (
        cd "$GUEST_INITRAMFS_DIR"
        find . -print0 | cpio --null -o --format=newc | gzip -9 >"$GUEST_INITRAMFS_IMG"
    ) >/dev/null
    need_file "$GUEST_INITRAMFS_IMG"
}

prepare_vm_config() {
    local cmdline ramdisk_path

    case "$X86_GUEST_BOOT_MODE" in
        rootfs)
            cmdline="console=ttyS0 earlyprintk=serial root=/dev/vda rw rootwait devtmpfs.mount=1 init=/init reboot=k panic=1 acpi=off pci=conf1 pci=nomsi irqpoll nox2apic tsc=unstable no_timer_check initcall_blacklist=ahci_pci_driver_init,i8042_init"
            ramdisk_path=""
            ;;
        initramfs)
            cmdline="console=ttyS0 earlyprintk=serial rdinit=/init init=/init reboot=k panic=1 acpi=off pci=conf1 pci=nomsi irqpoll nox2apic tsc=unstable no_timer_check initcall_blacklist=ahci_pci_driver_init,i8042_init"
            ramdisk_path="$GUEST_INITRAMFS_IMG"
            ;;
        *)
            echo "unsupported X86_GUEST_BOOT_MODE=$X86_GUEST_BOOT_MODE" >&2
            exit 1
            ;;
    esac

    python3 - "$BASE_AXVISOR_LINUX_VM_CONFIG" "$GENERATED_AXVISOR_LINUX_VM_CONFIG" \
        "$cmdline" "$ramdisk_path" "$X86_GUEST_IDENTITY_RAM_BASE" \
        "$X86_GUEST_IDENTITY_RAM_SIZE" "$X86_GUEST_CPU_NUM" \
        "$X86_GUEST_PHYS_CPU_IDS" <<'PY'
import re
import sys

src, dst, cmdline, ramdisk, ram_base, ram_size, cpu_num_raw, phys_cpu_ids_raw = sys.argv[1:]
text = open(src, encoding="utf-8").read()
cpu_num = int(cpu_num_raw, 0)
if cpu_num < 1:
    raise SystemExit("X86_GUEST_CPU_NUM must be >= 1")

if phys_cpu_ids_raw == "auto":
    if cpu_num == 1:
        # Preserve the historical single-vCPU config value.
        phys_cpu_ids = [1]
    else:
        phys_cpu_ids = list(range(cpu_num))
else:
    phys_cpu_ids = [int(item.strip(), 0) for item in phys_cpu_ids_raw.split(",") if item.strip()]
if len(phys_cpu_ids) != cpu_num:
    raise SystemExit(
        f"X86_GUEST_PHYS_CPU_IDS length {len(phys_cpu_ids)} != X86_GUEST_CPU_NUM {cpu_num}"
    )

def parse_size(value):
    raw = value.strip().replace("_", "")
    multipliers = {
        "K": 1024,
        "M": 1024 * 1024,
        "G": 1024 * 1024 * 1024,
        "KB": 1024,
        "MB": 1024 * 1024,
        "GB": 1024 * 1024 * 1024,
    }
    upper = raw.upper()
    for suffix, multiplier in sorted(multipliers.items(), key=lambda item: -len(item[0])):
        if upper.endswith(suffix):
            return int(upper[:-len(suffix)], 0) * multiplier
    return int(raw, 0)

def replace_kernel_key(text, key, value, after_key=None):
    line = f'{key} = "{value}"'
    pattern = rf'(?m)^{re.escape(key)} = ".*"$'
    text, count = re.subn(pattern, line, text, count=1)
    if count:
        return text
    if after_key:
        after_pattern = rf'(?m)^({re.escape(after_key)} = .*)$'
        text, count = re.subn(after_pattern, rf'\1\n{line}', text, count=1)
        if count:
            return text
    kernel_section = re.search(r"(?m)^\[kernel\]\s*$", text)
    if not kernel_section:
        raise SystemExit("missing [kernel] section")
    insert_at = kernel_section.end()
    return text[:insert_at] + "\n" + line + text[insert_at:]

def replace_identity_memory_region(text, base, size):
    base_int = int(base.replace("_", ""), 0)
    size_int = parse_size(size)
    replacement = f"[0x{base_int:08x}, 0x{size_int:08x}, 0x7, 1]"
    pattern = (
        r"(?m)(memory_regions\s*=\s*\[\s*\n"
        r"(?:\s*#.*\n)*)"
        r"\s*\[[^\]\n]+,\s*[^\]\n]+,\s*0x7,\s*1\]"
    )
    text, count = re.subn(pattern, rf"\1  {replacement}", text, count=1)
    if count != 1:
        raise SystemExit("failed to replace identity memory region")
    return text

def replace_base_cpu_config(text, cpu_num, phys_cpu_ids):
    text, cpu_count = re.subn(r"(?m)^cpu_num = \d+$", f"cpu_num = {cpu_num}", text, count=1)
    if cpu_count != 1:
        raise SystemExit("failed to replace cpu_num")
    phys_line = "phys_cpu_ids = [" + ", ".join(str(item) for item in phys_cpu_ids) + "]"
    text, phys_count = re.subn(r"(?m)^phys_cpu_ids = \[[^\]]*\]$", phys_line, text, count=1)
    if phys_count != 1:
        raise SystemExit("failed to replace phys_cpu_ids")
    return text

text = replace_base_cpu_config(text, cpu_num, phys_cpu_ids)
text = replace_kernel_key(text, "cmdline", cmdline)
text = replace_kernel_key(text, "ramdisk_path", ramdisk, after_key="ramdisk_load_addr")
text = replace_identity_memory_region(text, ram_base, ram_size)
open(dst, "w", encoding="utf-8").write(text)
PY
    AXVISOR_LINUX_VM_CONFIG="$GENERATED_AXVISOR_LINUX_VM_CONFIG"
    echo "[verify] generated VM config: $AXVISOR_LINUX_VM_CONFIG"
    echo "[verify] guest cpu_num: $X86_GUEST_CPU_NUM"
    echo "[verify] guest phys_cpu_ids: $X86_GUEST_PHYS_CPU_IDS"
}

build_kernel_and_module() {
    if [[ "$SKIP_BUILD" == "1" && "$X86_GUEST_BOOT_MODE" == "initramfs" ]]; then
        echo "[verify] initramfs mode embeds a generated ramdisk in axvisor_adapter.ko; forcing module rebuild"
        SKIP_BUILD=0
    fi

    if [[ "$SKIP_BUILD" == "1" ]]; then
        echo "[verify] skip build"
    else
        echo "[verify] build x86_64 host kernel image and axvisor_adapter.ko"
        if [[ "$X86_GUEST_BOOT_MODE" == "initramfs" ]]; then
            BUILD_DIR="$BUILD_DIR" \
            AXVISOR_ADAPTER_BUILD_BZIMAGE=1 \
            AXVISOR_LINUX_VM_CONFIG="$AXVISOR_LINUX_VM_CONFIG" \
            AXVISOR_LINUX_GUEST_KERNEL="$GUEST_KERNEL_IMAGE" \
            AXVISOR_LINUX_GUEST_INITRAMFS="$GUEST_INITRAMFS_IMG" \
                bash "$ROOT_DIR/tools/build-x86-linux-host-module.sh"
        else
            BUILD_DIR="$BUILD_DIR" \
            AXVISOR_ADAPTER_BUILD_BZIMAGE=1 \
            AXVISOR_LINUX_VM_CONFIG="$AXVISOR_LINUX_VM_CONFIG" \
            AXVISOR_LINUX_GUEST_KERNEL="$GUEST_KERNEL_IMAGE" \
                bash "$ROOT_DIR/tools/build-x86-linux-host-module.sh"
        fi
    fi

    need_file "$HOST_KERNEL_IMAGE"
    need_file "$GUEST_KERNEL_IMAGE"
    need_file "$KO_PATH"
}

prepare_host_initramfs() {
    local applet insmod_args

    echo "[verify] prepare Linux host initramfs: $HOST_INITRAMFS_IMG"
    rm -rf "$HOST_INITRAMFS_DIR"
    mkdir -p "$HOST_INITRAMFS_DIR/bin" "$HOST_INITRAMFS_DIR/dev" \
        "$HOST_INITRAMFS_DIR/proc" "$HOST_INITRAMFS_DIR/root" \
        "$HOST_INITRAMFS_DIR/sys" "$HOST_INITRAMFS_DIR/tmp"

    cp "$BUSYBOX" "$HOST_INITRAMFS_DIR/bin/busybox"
    chmod +x "$HOST_INITRAMFS_DIR/bin/busybox"
    for applet in sh mount uname dmesg insmod ls sleep mkdir cat grep sync \
        poweroff reboot tail kill ps; do
        ln -s busybox "$HOST_INITRAMFS_DIR/bin/$applet"
    done

    cp "$KO_PATH" "$HOST_INITRAMFS_DIR/root/axvisor_adapter.ko"
    insmod_args=""
    if [[ "$X86_GUEST_BOOT_MODE" == "initramfs" ]]; then
        insmod_args="x86_register_qemu_blk_intx=0"
    fi
    printf '%s\n' "$insmod_args" >"$HOST_INITRAMFS_DIR/root/axvisor-insmod-args"
    printf '%s\n' "$HOST_WAIT_FOR_AXVISOR_SYSTEM_DOWN" >"$HOST_INITRAMFS_DIR/root/axvisor-wait-system-down"

    cat >"$HOST_INITRAMFS_DIR/init" <<'EOF'
#!/bin/sh
set -eu

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

finish() {
    sync || true
    poweroff -f || reboot -f || sleep 3600
}

dump_context() {
    echo "[guest-host] dmesg tail"
    dmesg | tail -n 320 || true
}

fail() {
    reason="$1"
    echo "AXVISOR_X86_NATIVE_RUN_FAIL=$reason"
    dump_context
    finish
}

write_shell_cmd() {
    cmd="$1"
    fail_reason="$2"
    i=0
    while [ "$i" -lt 60 ]; do
        if printf '%s\n' "$cmd" > /proc/axvisor_shell; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    fail "$fail_reason"
}

mount -t proc proc /proc || true
mount -t sysfs sysfs /sys || true
mount -t devtmpfs devtmpfs /dev || true
mkdir -p /dev /proc /sys /tmp /root

echo "[guest-host] uname -a"
uname -a || true

if [ -e /sys/bus/pci/devices/0000:00:03.0/driver/unbind ]; then
    echo "[guest-host] unbind passthrough virtio-blk-pci 0000:00:03.0"
    echo 0000:00:03.0 > /sys/bus/pci/devices/0000:00:03.0/driver/unbind || true
fi

echo "[guest-host] insmod axvisor_adapter.ko"
INSMOD_ARGS="$(cat /root/axvisor-insmod-args 2>/dev/null || true)"
if ! insmod /root/axvisor_adapter.ko $INSMOD_ARGS; then
    fail "insmod"
fi

i=0
while [ "$i" -lt 30 ]; do
    if [ -e /proc/axvisor_shell ]; then
        break
    fi
    sleep 1
    i=$((i + 1))
done

if [ ! -e /proc/axvisor_shell ]; then
    fail "missing-axvisor-shell"
fi

echo "[guest-host] vm list"
write_shell_cmd "vm list" "vm-list-write"
sleep 1

echo "[guest-host] vm start 1"
write_shell_cmd "vm start 1" "vm-start-write"

WAIT_SYSTEM_DOWN="$(cat /root/axvisor-wait-system-down 2>/dev/null || echo 0)"
i=0
while [ "$i" -lt 180 ]; do
    if [ "$WAIT_SYSTEM_DOWN" = "1" ] &&
       dmesg | grep -q "vcpus::exit_reason system_down"; then
        echo "AXVISOR_X86_NATIVE_HOST_OBSERVED_SYSTEM_DOWN=1"
        finish
    fi
    sleep 1
    i=$((i + 1))
done

fail "timeout-inside-host"
EOF
    chmod +x "$HOST_INITRAMFS_DIR/init"

    (
        cd "$HOST_INITRAMFS_DIR"
        find . -print0 | cpio --null -o --format=newc | gzip -9 >"$HOST_INITRAMFS_IMG"
    ) >/dev/null
    need_file "$HOST_INITRAMFS_IMG"
}

launch_qemu() {
    local cpu_arg host_append
    local -a qemu_args

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

    host_append="console=ttyS0 earlyprintk=serial panic=-1 oops=panic nokaslr rcu_cpu_stall_suppress=1 nmi_watchdog=0 nowatchdog"
    host_append="$host_append memmap=${X86_GUEST_IDENTITY_RAM_SIZE}\$${X86_GUEST_IDENTITY_RAM_BASE}"

    echo "[verify] launch qemu accel=$QEMU_ACCEL cpu=$cpu_arg"
    echo "[verify] host append: $host_append"
    echo "[verify] qemu smp: $QEMU_SMP"
    qemu_args=(
        -nodefaults
        -no-reboot
        -display none
        -machine q35,sata=off,smbus=off,i8042=off,usb=off,graphics=off
        -monitor none
        -serial "file:$QEMU_LOG"
        -m "$QEMU_MEM"
        -smp "$QEMU_SMP"
        -accel "$QEMU_ACCEL"
        -cpu "$cpu_arg"
    )
    if [[ "$X86_GUEST_BOOT_MODE" == "rootfs" ]]; then
        qemu_args+=(
            -device virtio-blk-pci,drive=disk0,addr=03.0
            -drive "id=disk0,if=none,format=raw,file=$GUEST_ROOTFS_IMG"
        )
    fi
    qemu_args+=(
        -kernel "$HOST_KERNEL_IMAGE"
        -initrd "$HOST_INITRAMFS_IMG"
        -append "$host_append"
    )
    "$QEMU_BIN" "${qemu_args[@]}" &
    QEMU_PID=$!
}

wait_for_result() {
    local deadline
    local saw_pass=0

    deadline=$((SECONDS + TIMEOUT_SECS))
    while (( SECONDS < deadline )); do
        if grep -q "AXVISOR_X86_NATIVE_GUEST_PASS=1" "$QEMU_LOG"; then
            if [[ "$WAIT_FOR_POWEROFF_AFTER_PASS" == "1" ]]; then
                if (( saw_pass == 0 )); then
                    echo "[verify] guest pass marker detected; waiting for guest poweroff"
                    saw_pass=1
                fi
            else
                echo "[verify] pass"
                cleanup
                return 0
            fi
        fi
        if (( saw_pass == 1 )) && grep -q "reboot: Power down" "$QEMU_LOG"; then
            echo "[verify] pass"
            [[ -n "$QEMU_PID" ]] && wait "$QEMU_PID" 2>/dev/null || true
            QEMU_PID=""
            return 0
        fi
        if (( saw_pass == 1 )) && [[ "$WAIT_FOR_SYSTEM_DOWN_AFTER_PASS" == "1" ]] &&
            grep -q "vcpus::exit_reason system_down" "$QEMU_LOG" &&
            grep -q "kthread main entry returned" "$QEMU_LOG"; then
            echo "[verify] pass"
            cleanup
            return 0
        fi
        if grep -q "AXVISOR_X86_NATIVE_RUN_FAIL=" "$QEMU_LOG"; then
            echo "[verify] guest host reported failure" >&2
            tail -n 360 "$QEMU_LOG" >&2 || true
            cleanup
            return 1
        fi
        if [[ -n "$QEMU_PID" ]] && ! kill -0 "$QEMU_PID" >/dev/null 2>&1; then
            wait "$QEMU_PID" || true
            QEMU_PID=""
            if grep -q "AXVISOR_X86_NATIVE_GUEST_PASS=1" "$QEMU_LOG"; then
                if [[ "$WAIT_FOR_POWEROFF_AFTER_PASS" == "1" ]] &&
                    ! grep -q "reboot: Power down" "$QEMU_LOG"; then
                    echo "[verify] qemu exited after pass marker but without guest poweroff marker" >&2
                    tail -n 360 "$QEMU_LOG" >&2 || true
                    return 1
                fi
                echo "[verify] pass"
                return 0
            fi
            echo "[verify] qemu exited before pass marker" >&2
            tail -n 360 "$QEMU_LOG" >&2 || true
            return 1
        fi
        sleep "$POLL_SECS"
    done

    if (( saw_pass == 1 )) && [[ "$WAIT_FOR_SYSTEM_DOWN_AFTER_PASS" == "1" ]]; then
        echo "[verify] timeout after ${TIMEOUT_SECS}s waiting for AxVisor system_down after pass marker" >&2
    elif (( saw_pass == 1 )); then
        echo "[verify] timeout after ${TIMEOUT_SECS}s waiting for guest poweroff after pass marker" >&2
    else
        echo "[verify] timeout after ${TIMEOUT_SECS}s waiting for pass marker" >&2
    fi
    tail -n 420 "$QEMU_LOG" >&2 || true
    cleanup
    return 1
}

require_qemu_log() {
    local pattern="$1"
    local description="$2"

    if ! grep -Eq "$pattern" "$QEMU_LOG"; then
        echo "[verify] missing required marker: $description" >&2
        tail -n 420 "$QEMU_LOG" >&2 || true
        return 1
    fi
}

require_qemu_log_any() {
    local description="$1"
    shift

    local pattern
    for pattern in "$@"; do
        if grep -Eq "$pattern" "$QEMU_LOG"; then
            return 0
        fi
    done
    echo "[verify] missing required marker: $description" >&2
    tail -n 420 "$QEMU_LOG" >&2 || true
    return 1
}

reject_qemu_log() {
    local pattern="$1"
    local description="$2"

    if grep -Eq "$pattern" "$QEMU_LOG"; then
        echo "[verify] rejected marker found: $description" >&2
        grep -En "$pattern" "$QEMU_LOG" >&2 || true
        tail -n 420 "$QEMU_LOG" >&2 || true
        return 1
    fi
}

reject_unexpected_x86_gsi_activation() {
    local unexpected

    unexpected="$(grep -E "x86_irq::activate_gsi gsi=" "$QEMU_LOG" | \
        grep -Ev "x86_irq::activate_gsi gsi=19([^0-9]|$)" || true)"
    if [[ -n "$unexpected" ]]; then
        echo "[verify] unexpected x86 passthrough GSI activation" >&2
        printf '%s\n' "$unexpected" >&2
        tail -n 420 "$QEMU_LOG" >&2 || true
        return 1
    fi
}

extra_check_enabled() {
    local check="$1"

    case ",$X86_GUEST_EXTRA_CHECKS," in
        *",$check,"*) return 0 ;;
        *) return 1 ;;
    esac
}

extract_guest_result() {
    if [[ "$X86_GUEST_BOOT_MODE" != "rootfs" ]]; then
        return 0
    fi

    debugfs -R "cat $GUEST_RESULT_PATH" "$GUEST_ROOTFS_IMG" >"$GUEST_RESULT_TXT" 2>/dev/null || {
        echo "[verify] failed to extract guest smoke result: $GUEST_RESULT_PATH" >&2
        return 1
    }
}

require_guest_result() {
    local pattern="$1"
    local description="$2"

    if ! grep -Eq "$pattern" "$GUEST_RESULT_TXT"; then
        echo "[verify] missing guest result marker: $description" >&2
        cat "$GUEST_RESULT_TXT" >&2 || true
        return 1
    fi
}

validate_smoke_result() {
    reject_qemu_log "Kernel panic|panic:|panicked at|VM entry with invalid control|BUG:|Oops:|I/O error|EXT4-fs error|AXVISOR_X86_NATIVE_RUN_FAIL=" \
        "fatal guest/host failure"
    require_qemu_log "Run /init as init process" "guest executed /init"
    require_qemu_log "AXVISOR_X86_NATIVE_GUEST_PASS=1" "guest pass marker"

    if [[ "$X86_GUEST_BOOT_MODE" == "rootfs" ]]; then
        reject_unexpected_x86_gsi_activation
        require_qemu_log "VFS: Mounted root \\(ext4 filesystem\\)" "guest ext4 rootfs mounted"
        require_qemu_log "AXVISOR_X86_NATIVE_GUEST_HAS_DEV_VDA=1" "guest /dev/vda present"
        require_qemu_log "AXVISOR_X86_NATIVE_GUEST_HAS_SYS_BLOCK_VDA=1" "guest /sys/block/vda present"
        require_qemu_log "AXVISOR_X86_NATIVE_GUEST_ROOT_MOUNT_FS=ext4" "guest rootfs type ext4"
        require_qemu_log "AXVISOR_X86_NATIVE_GUEST_WRITE_TEST=1" "guest rootfs write test"
        require_qemu_log "requested x86 qemu blk INTx .*guest_gsi=19" \
            "Linux glue registered the passthrough QEMU virtio-blk INTx line"
        require_qemu_log "request-success-disabled.*guest_gsi=19.*intx_disabled=1" \
            "Linux glue keeps passthrough INTx disabled before guest route is ready"
        require_qemu_log "x86_irq::activate_gsi gsi=19" \
            "AxVisor activates passthrough guest GSI 19 after guest IOAPIC route is ready"
        require_qemu_log "x86 passthrough irq unmask irq=19 .*unmasked=1" \
            "Linux glue unmasks the real passthrough INTx line"
        require_qemu_log_any "Linux/AxVisor observes a pending virtio-blk INTx" \
            "x86 passthrough irq poll irq=19 .*pending=1" \
            "passthrough irq pending vm_id=1 irq_id=19 pending=true"
        require_qemu_log_any "AxVisor delivers the pending virtio-blk interrupt and receives guest EOI" \
            "x86 INTx state poll-pending .*guest_gsi=19.*interrupt_pending=1" \
            "x86_irq::eoi vector=0x20 gsi=19"
        extract_guest_result
        require_guest_result "^AXVISOR_X86_NATIVE_GUEST_PASS=1$" "guest result pass"
        require_guest_result "^HAS_DEV_VDA=1$" "guest result /dev/vda"
        require_guest_result "^HAS_SYS_BLOCK_VDA=1$" "guest result /sys/block/vda"
        require_guest_result "^ROOT_MOUNT_FS=ext4$" "guest result ext4 rootfs"
        require_guest_result "^EXPECTED_GUEST_CPUS=$X86_GUEST_CPU_NUM$" "guest result expected CPU count"
        require_guest_result "^CPUINFO_PROCESSOR_COUNT=$X86_GUEST_CPU_NUM$" "guest result /proc/cpuinfo CPU count"
        require_guest_result "^CPU_ONLINE_COUNT=$X86_GUEST_CPU_NUM$" "guest result online CPU count"
        require_guest_result "^SMOKE_WRITE_TEST=1$" "guest result write test"
        if extra_check_enabled timer; then
            require_qemu_log "x86_irq::pit_due .*count=([5-9]|[1-9][0-9])" \
                "AxVisor delivered repeated virtual PIT timer interrupts"
            require_qemu_log "x86_irq::pit_inject .*vector=0x30" \
                "AxVisor injected guest timer interrupt vector"
            require_guest_result "^TIMER_CHECK=1$" "timer check enabled"
            require_guest_result "^TIMER_MONOTONIC_OK=1$" "guest monotonic uptime"
            require_guest_result "^TIMER_SLEEP_WAKE_OK=1$" "guest sleep/wakeup completed within threshold"
        fi
        if extra_check_enabled irq; then
            require_qemu_log_any "Linux/AxVisor observed pending virtio-blk INTx" \
                "x86 passthrough irq poll irq=19 .*pending=1" \
                "passthrough irq pending vm_id=1 irq_id=19 pending=true"
            require_qemu_log_any "AxVisor delivered pending virtio-blk interrupt and received guest EOI" \
                "x86 INTx state poll-pending .*guest_gsi=19.*interrupt_pending=1" \
                "x86_irq::eoi vector=0x20 gsi=19"
            require_guest_result "^IRQ_CHECK=1$" "irq check enabled"
            require_guest_result "^IRQ_VIRTIO_DELTA_POSITIVE=1$" "guest virtio interrupt count increased"
        fi
        if extra_check_enabled mmio; then
            reject_qemu_log "vcpus::exit_reason mmio_(read|write)_unhandled|emu_device .* failed" \
                "unhandled MMIO/device access"
            require_guest_result "^MMIO_CHECK=1$" "mmio check enabled"
            require_guest_result "^MMIO_VIRTIO_RW_ITERATIONS=8$" "repeated virtio-blk I/O iterations"
            require_guest_result "^MMIO_VIRTIO_RW_OK=1$" "repeated virtio-blk I/O completed"
        fi
    fi
}

need_cmd bash
need_cmd cpio
need_cmd debugfs
need_cmd find
need_cmd gzip
need_cmd grep
need_cmd ln
need_cmd mkfs.ext4
need_cmd tail
need_cmd truncate
need_file "$QEMU_BIN"
need_file "$BUSYBOX"

trap cleanup EXIT
mkdir -p "$RUN_DIR"

case "$X86_GUEST_BOOT_MODE" in
    initramfs)
        prepare_guest_initramfs
        ;;
    rootfs)
        prepare_guest_rootfs
        ;;
    *)
        echo "unsupported X86_GUEST_BOOT_MODE=$X86_GUEST_BOOT_MODE" >&2
        exit 1
        ;;
esac
prepare_vm_config
build_kernel_and_module
prepare_host_initramfs
launch_qemu
wait_for_result
validate_smoke_result

echo "[verify] run dir: $RUN_DIR"
echo "[verify] qemu log: $QEMU_LOG"
echo "[verify] host kernel image: $HOST_KERNEL_IMAGE"
echo "[verify] module: $KO_PATH"
echo "[verify] guest kernel: $GUEST_KERNEL_IMAGE"
if [[ "$X86_GUEST_BOOT_MODE" == "rootfs" ]]; then
    echo "[verify] guest rootfs: $GUEST_ROOTFS_IMG"
    echo "[verify] smoke result: $GUEST_RESULT_TXT"
    cat "$GUEST_RESULT_TXT" 2>/dev/null || true
else
    echo "[verify] guest initramfs: $GUEST_INITRAMFS_IMG"
fi
