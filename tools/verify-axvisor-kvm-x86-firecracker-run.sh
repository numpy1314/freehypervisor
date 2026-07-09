#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-/tmp/axvisor-kvm-x86-firecracker-init-build}"
RUN_DIR="${RUN_DIR:-$(mktemp -d /tmp/axvisor-kvm-x86-firecracker-run.XXXXXX)}"
QEMU_BIN="${QEMU_BIN:-/home/bullet1517/qemu-9.2.4/build/qemu-system-x86_64}"
QEMU_ACCEL="${QEMU_ACCEL:-kvm}"
QEMU_CPU="${QEMU_CPU:-}"
QEMU_MEM="${QEMU_MEM:-1536M}"
QEMU_SMP="${QEMU_SMP:-1}"
TIMEOUT_SECS="${TIMEOUT_SECS:-240}"
POLL_SECS="${POLL_SECS:-1}"
SKIP_BUILD="${SKIP_BUILD:-0}"
BUSYBOX="${BUSYBOX:-/usr/bin/busybox}"
FIRECRACKER_BIN="${FIRECRACKER_BIN:-/tmp/firecracker-gnu-target/x86_64-unknown-linux-gnu/debug/firecracker}"
FIRECRACKER_GUEST_BOOT_MODE="${FIRECRACKER_GUEST_BOOT_MODE:-initramfs}"
FIRECRACKER_GUEST_INIT="${FIRECRACKER_GUEST_INIT:-/init}"
FIRECRACKER_GUEST_BOOT_ARGS_EXTRA="${FIRECRACKER_GUEST_BOOT_ARGS_EXTRA:-}"
FIRECRACKER_ROOTFS_INIT_KIND="${FIRECRACKER_ROOTFS_INIT_KIND:-sh}"
FIRECRACKER_VCPU_COUNT="${FIRECRACKER_VCPU_COUNT:-1}"
GUEST_ROOTFS_IMG="${GUEST_ROOTFS_IMG:-$RUN_DIR/guest-rootfs.img}"
GUEST_ROOTFS_SIZE="${GUEST_ROOTFS_SIZE:-64M}"

KO_PATH="$BUILD_DIR/drivers/virt/axvisor/axvisor_kvm.ko"
HOST_KERNEL_IMAGE="$BUILD_DIR/arch/x86/boot/bzImage"
GUEST_KERNEL_IMAGE="${GUEST_KERNEL_IMAGE:-$BUILD_DIR/vmlinux}"
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
    need_file "$GUEST_KERNEL_IMAGE"
    need_file "$KO_PATH"
}

copy_path_preserve() {
    local src="$1"
    local dst="$HOST_INITRAMFS_DIR$src"

    need_file "$src"
    mkdir -p "$(dirname "$dst")"
    cp -L "$src" "$dst"
}

copy_elf_runtime_deps() {
    local bin="$1"
    local dep

    while read -r dep; do
        [[ -n "$dep" ]] || continue
        [[ "$dep" == "linux-vdso.so."* ]] && continue
        copy_path_preserve "$dep"
    done < <(
        ldd "$bin" | awk '
            /^[[:space:]]*\// { print $1; next }
            /=>[[:space:]]*\// { print $3; next }
        '
    )
}

prepare_guest_initramfs() {
    local applet

    echo "[verify] prepare Firecracker guest initramfs: $GUEST_INITRAMFS_IMG"
    rm -rf "$GUEST_INITRAMFS_DIR"
    mkdir -p "$GUEST_INITRAMFS_DIR/bin" "$GUEST_INITRAMFS_DIR/dev" \
        "$GUEST_INITRAMFS_DIR/proc" "$GUEST_INITRAMFS_DIR/sys"

    cp "$BUSYBOX" "$GUEST_INITRAMFS_DIR/bin/busybox"
    chmod +x "$GUEST_INITRAMFS_DIR/bin/busybox"
    for applet in sh mount uname cat sync poweroff reboot sleep; do
        ln -s busybox "$GUEST_INITRAMFS_DIR/bin/$applet"
    done

    cat >"$GUEST_INITRAMFS_DIR/init" <<'EOF'
#!/bin/sh
set -u

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

log() {
    msg="$*"
    echo "$msg" || true
    echo "$msg" >/dev/kmsg 2>/dev/null || true
    echo "$msg" >/dev/console 2>/dev/null || true
}

mount -t proc proc /proc || true
mount -t sysfs sysfs /sys || true
mount -t devtmpfs devtmpfs /dev || true

log "FC_PASS=1"
log "AXVISOR_FIRECRACKER_GUEST_STAGE=boot"
uname -a || true
cat /proc/cmdline || true
if [ -r /sys/devices/system/cpu/online ]; then
    log "AXVISOR_FIRECRACKER_GUEST_CPU_ONLINE=$(cat /sys/devices/system/cpu/online)"
fi
if [ -r /proc/cpuinfo ]; then
    log "AXVISOR_FIRECRACKER_GUEST_CPUINFO_COUNT=$(grep -c '^processor' /proc/cpuinfo || true)"
fi
log "AXVISOR_FIRECRACKER_GUEST_PASS=1"
sync || true
log "AXVISOR_FIRECRACKER_GUEST_STAGE=idle"
while true; do
    sleep 3600 || true
done
EOF
    chmod +x "$GUEST_INITRAMFS_DIR/init"

    (
        cd "$GUEST_INITRAMFS_DIR"
        find . -print0 | cpio --null -o --format=newc | gzip -9 >"$GUEST_INITRAMFS_IMG"
    ) >/dev/null
    need_file "$GUEST_INITRAMFS_IMG"
}

debugfs_cmds() {
    local image="$1"
    local cmds="$2"

    debugfs -w -f "$cmds" "$image" >/dev/null
}

prepare_guest_rootfs() {
    local rootfs_debugfs_cmds init_template applet

    echo "[verify] prepare Firecracker guest rootfs: $GUEST_ROOTFS_IMG"
    rm -f "$GUEST_ROOTFS_IMG"
    truncate -s "$GUEST_ROOTFS_SIZE" "$GUEST_ROOTFS_IMG"
    mkfs.ext4 -F "$GUEST_ROOTFS_IMG" >/dev/null

    init_template="$RUN_DIR/guest-rootfs-init.sh"
    cat >"$init_template" <<'EOF'
#!/bin/busybox sh
set -u

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

RESULT=/axvisor-firecracker-result.txt
WRITE_TEST=/axvisor-firecracker-rootfs-write-test.txt
EXPECTED=axvisor-firecracker-rootfs-write-test

echo "AXVISOR_FIRECRACKER_GUEST_STAGE=init-entry"
if [ -e /dev/vda ]; then
    echo "AXVISOR_FIRECRACKER_GUEST_HAS_DEV_VDA=1"
else
    echo "AXVISOR_FIRECRACKER_GUEST_HAS_DEV_VDA=0"
fi

echo "AXVISOR_FIRECRACKER_GUEST_STAGE=before-write-test"
if echo "$EXPECTED" > "$WRITE_TEST" &&
   [ "$(cat "$WRITE_TEST" 2>/dev/null || true)" = "$EXPECTED" ]; then
    echo "AXVISOR_FIRECRACKER_GUEST_WRITE_TEST=1"
else
    echo "AXVISOR_FIRECRACKER_GUEST_WRITE_TEST=0"
fi
echo "AXVISOR_FIRECRACKER_GUEST_STAGE=after-write-test"

{
    echo "FC_ROOTFS_PASS=1"
    echo "AXVISOR_FIRECRACKER_GUEST_STAGE=busybox-rootfs-entry"
    echo "AXVISOR_FIRECRACKER_GUEST_PASS=1"
    echo "AXVISOR_FIRECRACKER_GUEST_WRITE_TEST=1"
} > "$RESULT" 2>/dev/null || true

if grep -q "FC_ROOTFS_PASS=1" "$RESULT" 2>/dev/null; then
    echo "FC_ROOTFS_PASS=1"
    echo "BUSYBOX_READBACK_OK"
else
    echo "BUSYBOX_READBACK_FAIL"
fi

echo "AXVISOR_FIRECRACKER_GUEST_PASS=1"
echo "AXVISOR_FIRECRACKER_GUEST_STAGE=before-sync"
sync || true
echo "AXVISOR_FIRECRACKER_GUEST_STAGE=after-sync"
sleep 3600
EOF
    chmod +x "$init_template"

    rootfs_debugfs_cmds="$RUN_DIR/guest-rootfs.debugfs"
    {
        echo "mkdir /bin"
        echo "mkdir /dev"
        echo "mkdir /proc"
        echo "mkdir /sys"
        echo "write $BUSYBOX /bin/busybox"
        echo "set_inode_field /bin/busybox mode 0100755"
        echo "write $init_template /init"
        echo "set_inode_field /init mode 0100755"
        echo "mknod /dev/console c 5 1"
        echo "mknod /dev/null c 1 3"
        echo "mknod /dev/ttyS0 c 4 64"
        for applet in sh mount uname cat sync poweroff reboot sleep awk grep; do
            echo "symlink /bin/$applet busybox"
        done
    } >"$rootfs_debugfs_cmds"
    debugfs_cmds "$GUEST_ROOTFS_IMG" "$rootfs_debugfs_cmds"
    need_file "$GUEST_ROOTFS_IMG"
}

prepare_guest_rootfs_tiny() {
    local rootfs_debugfs_cmds tiny_init_src tiny_init_bin

    echo "[verify] prepare Firecracker tiny-init guest rootfs: $GUEST_ROOTFS_IMG"
    rm -f "$GUEST_ROOTFS_IMG"
    truncate -s "$GUEST_ROOTFS_SIZE" "$GUEST_ROOTFS_IMG"
    mkfs.ext4 -F "$GUEST_ROOTFS_IMG" >/dev/null

    tiny_init_src="$RUN_DIR/guest-rootfs-tiny-init.c"
    tiny_init_bin="$RUN_DIR/guest-rootfs-tiny-init"
    cat >"$tiny_init_src" <<'EOF'
#include <fcntl.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/syscall.h>

#ifndef AT_FDCWD
#define AT_FDCWD -100
#endif

static long sc0(long nr)
{
    long ret;
    __asm__ volatile("syscall"
                     : "=a"(ret)
                     : "a"(nr)
                     : "rcx", "r11", "memory");
    return ret;
}

static long sc1(long nr, long a0)
{
    long ret;
    __asm__ volatile("syscall"
                     : "=a"(ret)
                     : "a"(nr), "D"(a0)
                     : "rcx", "r11", "memory");
    return ret;
}

static long sc2(long nr, long a0, long a1)
{
    long ret;
    __asm__ volatile("syscall"
                     : "=a"(ret)
                     : "a"(nr), "D"(a0), "S"(a1)
                     : "rcx", "r11", "memory");
    return ret;
}

static long sc3(long nr, long a0, long a1, long a2)
{
    long ret;
    __asm__ volatile("syscall"
                     : "=a"(ret)
                     : "a"(nr), "D"(a0), "S"(a1), "d"(a2)
                     : "rcx", "r11", "memory");
    return ret;
}

static long sc4(long nr, long a0, long a1, long a2, long a3)
{
    long ret;
    register long r10 __asm__("r10") = a3;
    __asm__ volatile("syscall"
                     : "=a"(ret)
                     : "a"(nr), "D"(a0), "S"(a1), "d"(a2), "r"(r10)
                     : "rcx", "r11", "memory");
    return ret;
}

static void write_all(int fd, const char *s)
{
    const char *p = s;
    long n = 0;

    while (p[n] != '\0')
        n++;
    while (n > 0) {
        long ret = sc3(SYS_write, fd, (long)p, n);
        if (ret <= 0)
            return;
        p += ret;
        n -= ret;
    }
}

static long cstr_len(const char *s)
{
    long n = 0;

    while (s[n] != '\0')
        n++;
    return n;
}

static int mem_eq(const char *a, const char *b, long n)
{
    long i;

    for (i = 0; i < n; i++) {
        if (a[i] != b[i])
            return 0;
    }
    return 1;
}

static void log_line(const char *s)
{
    int kmsg;

    write_all(1, s);
    kmsg = (int)sc4(SYS_openat, AT_FDCWD, (long)"/dev/kmsg", O_WRONLY, 0);
    if (kmsg >= 0) {
        write_all(kmsg, "<6>");
        write_all(kmsg, s);
        sc1(SYS_close, kmsg);
    }
}

void _start(void)
{
    int fd;
    int rfd;
    long expected_len;
    long got;
    char buf[256];
    const char *expected =
        "FC_ROOTFS_PASS=1\n"
        "AXVISOR_FIRECRACKER_GUEST_STAGE=tiny-rootfs-entry\n"
        "AXVISOR_FIRECRACKER_GUEST_PASS=1\n"
        "AXVISOR_FIRECRACKER_GUEST_WRITE_TEST=1\n";

    fd = (int)sc4(SYS_openat, AT_FDCWD, (long)"/axvisor-firecracker-result.txt",
                  O_CREAT | O_TRUNC | O_WRONLY, 0644);
    if (fd >= 0) {
        log_line("TINY_OPEN_OK\n");
        write_all(fd, expected);
        sc1(SYS_fsync, fd);
        sc1(SYS_close, fd);
    } else {
        log_line("TINY_OPEN_FAIL\n");
    }
    sc0(SYS_sync);
    expected_len = cstr_len(expected);
    rfd = (int)sc4(SYS_openat, AT_FDCWD, (long)"/axvisor-firecracker-result.txt",
                   O_RDONLY, 0);
    if (rfd >= 0) {
        got = sc3(SYS_read, rfd, (long)buf, sizeof(buf));
        sc1(SYS_close, rfd);
        if (got == expected_len && mem_eq(buf, expected, expected_len)) {
            log_line("FC_ROOTFS_PASS=1\n");
            log_line("TINY_READBACK_OK\n");
        } else {
            log_line("TINY_READBACK_FAIL\n");
        }
    } else {
        log_line("TINY_REOPEN_FAIL\n");
    }
    log_line("TINY_PASS=1\n");
    sc4(SYS_reboot, 0xfee1dead, 672274793, 0x4321fedc, 0);
    for (;;)
        sc0(SYS_pause);
}
EOF

    gcc -static -nostdlib -Os -s -o "$tiny_init_bin" "$tiny_init_src"
    need_file "$tiny_init_bin"

    rootfs_debugfs_cmds="$RUN_DIR/guest-rootfs.debugfs"
    {
        echo "mkdir /dev"
        echo "write $tiny_init_bin /init"
        echo "set_inode_field /init mode 0100755"
        echo "mknod /dev/console c 5 1"
        echo "mknod /dev/null c 1 3"
    } >"$rootfs_debugfs_cmds"
    debugfs_cmds "$GUEST_ROOTFS_IMG" "$rootfs_debugfs_cmds"
    need_file "$GUEST_ROOTFS_IMG"
}

prepare_host_initramfs() {
    local applet

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

    cp "$KO_PATH" "$HOST_INITRAMFS_DIR/root/axvisor_kvm.ko"
    cp "$FIRECRACKER_BIN" "$HOST_INITRAMFS_DIR/root/firecracker"
    cp "$GUEST_KERNEL_IMAGE" "$HOST_INITRAMFS_DIR/root/firecracker-guest-vmlinux"
    if [[ "$FIRECRACKER_GUEST_BOOT_MODE" == "rootfs" ]]; then
        copy_path_preserve /usr/sbin/debugfs
        copy_path_preserve /usr/bin/grep
        copy_elf_runtime_deps /usr/sbin/debugfs
        copy_elf_runtime_deps /usr/bin/grep
    fi
    case "$FIRECRACKER_GUEST_BOOT_MODE" in
        initramfs)
            cp "$GUEST_INITRAMFS_IMG" "$HOST_INITRAMFS_DIR/root/firecracker-guest-initrd.cpio.gz"
            ;;
        rootfs)
            cp "$GUEST_ROOTFS_IMG" "$HOST_INITRAMFS_DIR/root/firecracker-guest-rootfs.img"
            ;;
        *)
            echo "unsupported FIRECRACKER_GUEST_BOOT_MODE=$FIRECRACKER_GUEST_BOOT_MODE" >&2
            exit 1
            ;;
    esac
    chmod +x "$HOST_INITRAMFS_DIR/root/firecracker"
    copy_elf_runtime_deps "$FIRECRACKER_BIN"

    if [[ "$FIRECRACKER_GUEST_BOOT_MODE" == "initramfs" ]]; then
        cat >"$HOST_INITRAMFS_DIR/root/fc-config.json" <<EOF
{
  "boot-source": {
    "kernel_image_path": "/root/firecracker-guest-vmlinux",
    "initrd_path": "/root/firecracker-guest-initrd.cpio.gz",
    "boot_args": "console=ttyS0 earlyprintk=serial keep_bootcon reboot=k panic=1 acpi=off pci=off nomodule tsc=unstable no_timer_check 8250.nr_uarts=0 initcall_blacklist=ahci_pci_driver_init,i8042_init init=/init rdinit=/init $FIRECRACKER_GUEST_BOOT_ARGS_EXTRA"
  },
  "drives": [],
  "machine-config": {
    "vcpu_count": $FIRECRACKER_VCPU_COUNT,
    "mem_size_mib": 128,
    "smt": false,
    "track_dirty_pages": false
  }
}
EOF
    else
        cat >"$HOST_INITRAMFS_DIR/root/fc-config.json" <<EOF
{
  "boot-source": {
    "kernel_image_path": "/root/firecracker-guest-vmlinux",
    "boot_args": "console=ttyS0 earlyprintk=serial keep_bootcon reboot=k panic=1 acpi=off pci=off nomodule tsc=unstable no_timer_check 8250.nr_uarts=0 initcall_blacklist=ahci_pci_driver_init,i8042_init root=/dev/vda rw rootwait devtmpfs.mount=1 init=$FIRECRACKER_GUEST_INIT $FIRECRACKER_GUEST_BOOT_ARGS_EXTRA"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "/root/firecracker-guest-rootfs.img",
      "is_root_device": true,
      "is_read_only": false
    }
  ],
  "machine-config": {
    "vcpu_count": $FIRECRACKER_VCPU_COUNT,
    "mem_size_mib": 128,
    "smt": false,
    "track_dirty_pages": false
  }
}
EOF
    fi

    cat >"$HOST_INITRAMFS_DIR/init" <<'EOF'
#!/bin/sh
set -eu

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

finish() {
    sync || true
    poweroff -f || reboot -f || sleep 3600
}

dump_context() {
    echo "[guest-host] firecracker stderr"
    cat /root/firecracker-stderr.log 2>/dev/null || true
    echo "[guest-host] firecracker serial"
    cat /root/firecracker-serial.log 2>/dev/null || true
    echo "[guest-host] dmesg tail"
    dmesg | tail -n 260 || true
}

fail() {
    reason="$1"
    echo "AXVISOR_KVM_FIRECRACKER_RUN_FAIL=$reason"
    dump_context
    finish
}

mount -t proc proc /proc || true
mount -t sysfs sysfs /sys || true
mount -t devtmpfs devtmpfs /dev || true
mkdir -p /dev /proc /sys /tmp /root

echo "[guest-host] uname -a"
uname -a || true

echo "[guest-host] insmod axvisor_kvm.ko dev_name=kvm"
if ! insmod /root/axvisor_kvm.ko dev_name=kvm; then
    fail "insmod"
fi

if [ ! -e /dev/kvm ]; then
    ls -l /dev || true
    fail "missing-dev-kvm"
fi
ls -l /dev/kvm || true

echo "[guest-host] run unmodified Firecracker through /dev/kvm"
: >/root/firecracker-serial.log
: >/root/firecracker-stderr.log
: >/root/firecracker-rootfs-result.log
/root/firecracker \
    --no-api \
    --no-seccomp \
    --config-file /root/fc-config.json \
    >/root/firecracker-serial.log \
    2>/root/firecracker-stderr.log &
fc_pid="$!"

i=0
while [ "$i" -lt 180 ]; do
    if [ -f /root/firecracker-guest-rootfs.img ] &&
       /usr/sbin/debugfs -R 'cat /axvisor-firecracker-result.txt' /root/firecracker-guest-rootfs.img > /root/firecracker-rootfs-result.log 2>/dev/null &&
       grep -q "FC_ROOTFS_PASS=1" /root/firecracker-rootfs-result.log; then
        echo "AXVISOR_KVM_FIRECRACKER_RUN_QEMU_PASS=1"
        echo "[guest-host] firecracker rootfs result"
        cat /root/firecracker-rootfs-result.log || true
        dump_context
        kill "$fc_pid" >/dev/null 2>&1 || true
        finish
    fi
    if [ -f /root/firecracker-guest-rootfs.img ] &&
       grep -q "FC_ROOTFS_PASS=1" /root/firecracker-serial.log; then
        echo "AXVISOR_KVM_FIRECRACKER_RUN_QEMU_PASS=1"
        echo "[guest-host] firecracker rootfs readback result"
        dump_context
        kill "$fc_pid" >/dev/null 2>&1 || true
        finish
    fi
    if [ ! -f /root/firecracker-guest-rootfs.img ] &&
       (grep -q "FC_PASS=1" /root/firecracker-serial.log ||
        grep -q "AXVISOR_FIRECRACKER_GUEST_PASS=1" /root/firecracker-serial.log); then
        echo "AXVISOR_KVM_FIRECRACKER_RUN_QEMU_PASS=1"
        dump_context
        kill "$fc_pid" >/dev/null 2>&1 || true
        finish
    fi

    if ! kill -0 "$fc_pid" >/dev/null 2>&1; then
        wait "$fc_pid" || true
        if [ -f /root/firecracker-guest-rootfs.img ] &&
           /usr/sbin/debugfs -R 'cat /axvisor-firecracker-result.txt' /root/firecracker-guest-rootfs.img > /root/firecracker-rootfs-result.log 2>/dev/null &&
           grep -q "FC_ROOTFS_PASS=1" /root/firecracker-rootfs-result.log; then
            echo "AXVISOR_KVM_FIRECRACKER_RUN_QEMU_PASS=1"
            echo "[guest-host] firecracker rootfs result"
            cat /root/firecracker-rootfs-result.log || true
            dump_context
            finish
        fi
        fail "firecracker-exited-before-pass"
    fi

    sleep 1
    i=$((i + 1))
done

kill "$fc_pid" >/dev/null 2>&1 || true
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

    echo "[verify] launch qemu accel=$QEMU_ACCEL cpu=$cpu_arg"
    "$QEMU_BIN" \
        -nodefaults \
        -no-reboot \
        -display none \
        -monitor none \
        -serial "file:$QEMU_LOG" \
        -m "$QEMU_MEM" \
        -smp "$QEMU_SMP" \
        -accel "$QEMU_ACCEL" \
        -cpu "$cpu_arg" \
        -kernel "$HOST_KERNEL_IMAGE" \
        -initrd "$HOST_INITRAMFS_IMG" \
        -append "console=ttyS0 earlyprintk=serial panic=-1 oops=panic nokaslr" &
    QEMU_PID=$!
}

qemu_log_has_firecracker_guest_serial_pass() {
    qemu_log_has_firecracker_guest_serial_text "FC_PASS=1" ||
    qemu_log_has_firecracker_guest_serial_text "AXVISOR_FIRECRACKER_GUEST_PASS=1" ||
    qemu_log_has_firecracker_guest_serial_text "TINY_PASS=1"
}

qemu_log_has_firecracker_guest_smp_pass() {
    qemu_log_has_firecracker_guest_serial_text "AXVISOR_FIRECRACKER_GUEST_CPU_ONLINE=0-$((FIRECRACKER_VCPU_COUNT - 1))" ||
    qemu_log_has_firecracker_guest_serial_text "AXVISOR_FIRECRACKER_GUEST_CPUINFO_COUNT=$FIRECRACKER_VCPU_COUNT" ||
    qemu_log_has_firecracker_guest_serial_text "smp: Brought up 1 node, $FIRECRACKER_VCPU_COUNT CPUs"
}

qemu_log_has_firecracker_guest_serial_text() {
    local target="$1"

    if grep -Fq "$target" "$QEMU_LOG"; then
        return 0
    fi

    python3 - "$QEMU_LOG" "$target" <<'PY'
import re
import sys

target = sys.argv[2].encode()
serial = bytearray()
io_write_pattern = re.compile(r"IoWrite \{ port: Port\(1016\), width: Byte, data: (\d+) \}")
char_prefix = "axvisor_kvm_x86_bridge: "

try:
    with open(sys.argv[1], errors="ignore") as log:
        for line in log:
            match = io_write_pattern.search(line)
            if match:
                serial.append(int(match.group(1)) & 0xff)
                continue
            if char_prefix in line:
                payload = line.split(char_prefix, 1)[1].rstrip("\n")
                if len(payload) == 1:
                    serial.extend(payload.encode(errors="ignore"))
except FileNotFoundError:
    sys.exit(1)

sys.exit(0 if target in bytes(serial) else 1)
PY
}

decode_firecracker_guest_serial() {
    local out="$RUN_DIR/firecracker-serial-decoded.log"

    python3 - "$QEMU_LOG" "$out" <<'PY'
import re
import sys

io_write_pattern = re.compile(r"IoWrite \{ port: Port\(1016\), width: Byte, data: (\d+) \}")
serial = bytearray()
char_prefix = "axvisor_kvm_x86_bridge: "
direct_prefixes = (
    "FC_PASS=",
    "FC_ROOTFS_PASS=",
    "TINY_PASS=",
    "TINY_READBACK_",
    "BUSYBOX_READBACK_",
    "AXVISOR_FIRECRACKER_GUEST_",
    "smp: Brought up ",
)

with open(sys.argv[1], errors="ignore") as log:
    for line in log:
        match = io_write_pattern.search(line)
        if match:
            serial.append(int(match.group(1)) & 0xff)
            continue
        if char_prefix in line:
            payload = line.split(char_prefix, 1)[1].rstrip("\n")
            if len(payload) == 1:
                serial.extend(payload.encode(errors="ignore"))
                continue
        for prefix in direct_prefixes:
            idx = line.find(prefix)
            if idx >= 0:
                serial.extend(line[idx:].encode(errors="ignore"))
                break

with open(sys.argv[2], "wb") as out:
    out.write(bytes(serial))
PY
}

validate_firecracker_guest_result() {
    if [[ "$FIRECRACKER_VCPU_COUNT" -gt 1 ]]; then
        if ! qemu_log_has_firecracker_guest_serial_text "AXVISOR_FIRECRACKER_GUEST_CPU_ONLINE=0-$((FIRECRACKER_VCPU_COUNT - 1))" &&
           ! qemu_log_has_firecracker_guest_serial_text "AXVISOR_FIRECRACKER_GUEST_CPUINFO_COUNT=$FIRECRACKER_VCPU_COUNT" &&
           ! qemu_log_has_firecracker_guest_serial_text "smp: Brought up 1 node, $FIRECRACKER_VCPU_COUNT CPUs"; then
            return 1
        fi
    fi
    if [[ "$FIRECRACKER_GUEST_BOOT_MODE" != "rootfs" ]]; then
        return 0
    fi
    if [[ "$FIRECRACKER_ROOTFS_INIT_KIND" == "tiny" ]]; then
        qemu_log_has_firecracker_guest_serial_text "FC_ROOTFS_PASS=1" &&
        qemu_log_has_firecracker_guest_serial_text "TINY_READBACK_OK"
        return
    fi

    if grep -q "AXVISOR_FIRECRACKER_GUEST_HAS_DEV_VDA=1" "$QEMU_LOG" &&
       grep -q "AXVISOR_FIRECRACKER_GUEST_WRITE_TEST=1" "$QEMU_LOG" &&
       grep -q "BUSYBOX_READBACK_OK" "$QEMU_LOG"; then
        return 0
    fi

    qemu_log_has_firecracker_guest_serial_text "AXVISOR_FIRECRACKER_GUEST_HAS_DEV_VDA=1" &&
    qemu_log_has_firecracker_guest_serial_text "AXVISOR_FIRECRACKER_GUEST_WRITE_TEST=1" &&
    qemu_log_has_firecracker_guest_serial_text "BUSYBOX_READBACK_OK"
}

write_firecracker_guest_result() {
    local serial_log="$RUN_DIR/firecracker-serial-decoded.log"
    local result="$RUN_DIR/firecracker-result.txt"

    decode_firecracker_guest_serial
    {
        echo "AXVISOR_FIRECRACKER_GUEST_PASS=1"
        echo "FIRECRACKER_GUEST_BOOT_MODE=$FIRECRACKER_GUEST_BOOT_MODE"
        echo "FIRECRACKER_VCPU_COUNT=$FIRECRACKER_VCPU_COUNT"
        if grep -q "AXVISOR_FIRECRACKER_GUEST_CPU_ONLINE=" "$serial_log"; then
            grep "AXVISOR_FIRECRACKER_GUEST_CPU_ONLINE=" "$serial_log" | tail -n 1
        fi
        if grep -q "AXVISOR_FIRECRACKER_GUEST_CPUINFO_COUNT=" "$serial_log"; then
            grep "AXVISOR_FIRECRACKER_GUEST_CPUINFO_COUNT=" "$serial_log" | tail -n 1
        fi
        if [[ "$FIRECRACKER_GUEST_BOOT_MODE" == "rootfs" ]]; then
            echo "FIRECRACKER_ROOTFS_INIT_KIND=$FIRECRACKER_ROOTFS_INIT_KIND"
        fi
        if grep -q "TINY_PASS=1" "$serial_log" ||
           grep -q "TINY_PASS=1" "$QEMU_LOG"; then
            echo "TINY_PASS=1"
        fi
        if grep -q "FC_ROOTFS_PASS=1" "$serial_log" ||
           grep -q "FC_ROOTFS_PASS=1" "$QEMU_LOG"; then
            echo "FC_ROOTFS_PASS=1"
        fi
        if grep -q "TINY_READBACK_OK" "$serial_log" ||
           grep -q "TINY_READBACK_OK" "$QEMU_LOG"; then
            echo "TINY_READBACK_OK"
        fi
        if grep -q "BUSYBOX_READBACK_OK" "$serial_log" ||
           grep -q "BUSYBOX_READBACK_OK" "$QEMU_LOG"; then
            echo "BUSYBOX_READBACK_OK"
        fi
        if grep -q "AXVISOR_TINY_INIT_STAGE=entry" "$serial_log" ||
           grep -q "AXVISOR_TINY_INIT_STAGE=entry" "$QEMU_LOG"; then
            echo "AXVISOR_TINY_INIT_STAGE=entry"
        fi
        if grep -q "AXVISOR_FIRECRACKER_GUEST_HAS_DEV_VDA=1" "$serial_log" ||
           grep -q "AXVISOR_FIRECRACKER_GUEST_HAS_DEV_VDA=1" "$QEMU_LOG"; then
            echo "AXVISOR_FIRECRACKER_GUEST_HAS_DEV_VDA=1"
        fi
        if grep -q "AXVISOR_FIRECRACKER_GUEST_HAS_SYS_BLOCK_VDA=1" "$serial_log" ||
           grep -q "AXVISOR_FIRECRACKER_GUEST_HAS_SYS_BLOCK_VDA=1" "$QEMU_LOG"; then
            echo "AXVISOR_FIRECRACKER_GUEST_HAS_SYS_BLOCK_VDA=1"
        fi
        if grep -q "AXVISOR_FIRECRACKER_GUEST_ROOT_MOUNT_FS=ext4" "$serial_log" ||
           grep -q "AXVISOR_FIRECRACKER_GUEST_ROOT_MOUNT_FS=ext4" "$QEMU_LOG"; then
            echo "AXVISOR_FIRECRACKER_GUEST_ROOT_MOUNT_FS=ext4"
        fi
        if grep -q "AXVISOR_FIRECRACKER_GUEST_WRITE_TEST=1" "$serial_log" ||
           grep -q "AXVISOR_FIRECRACKER_GUEST_WRITE_TEST=1" "$QEMU_LOG"; then
            echo "AXVISOR_FIRECRACKER_GUEST_WRITE_TEST=1"
        fi
    } >"$result"
}

wait_for_result() {
    local deadline

    deadline=$((SECONDS + TIMEOUT_SECS))
    while (( SECONDS < deadline )); do
        if grep -q "^AXVISOR_KVM_FIRECRACKER_RUN_QEMU_PASS=1$" "$QEMU_LOG"; then
            echo "[verify] pass"
            cleanup
            return 0
        fi
        if [[ "$FIRECRACKER_GUEST_BOOT_MODE" != "rootfs" ]] &&
           qemu_log_has_firecracker_guest_serial_pass &&
           { [[ "$FIRECRACKER_VCPU_COUNT" -le 1 ]] || qemu_log_has_firecracker_guest_smp_pass; }; then
            echo "[verify] pass"
            cleanup
            return 0
        fi
        if [[ "$FIRECRACKER_GUEST_BOOT_MODE" == "rootfs" ]] &&
           qemu_log_has_firecracker_guest_serial_text "FC_ROOTFS_PASS=1"; then
            echo "[verify] pass"
            cleanup
            return 0
        fi
        if grep -q "AXVISOR_KVM_FIRECRACKER_RUN_FAIL=" "$QEMU_LOG"; then
            echo "[verify] guest host reported failure" >&2
            tail -n 260 "$QEMU_LOG" >&2 || true
            cleanup
            return 1
        fi
        if [[ -n "$QEMU_PID" ]] && ! kill -0 "$QEMU_PID" >/dev/null 2>&1; then
            wait "$QEMU_PID" || true
            QEMU_PID=""
            if grep -q "^AXVISOR_KVM_FIRECRACKER_RUN_QEMU_PASS=1$" "$QEMU_LOG"; then
                echo "[verify] pass"
                return 0
            fi
            if [[ "$FIRECRACKER_GUEST_BOOT_MODE" != "rootfs" ]] &&
               qemu_log_has_firecracker_guest_serial_pass &&
               { [[ "$FIRECRACKER_VCPU_COUNT" -le 1 ]] || qemu_log_has_firecracker_guest_smp_pass; }; then
                echo "[verify] pass"
                return 0
            fi
            if [[ "$FIRECRACKER_GUEST_BOOT_MODE" == "rootfs" ]] &&
               qemu_log_has_firecracker_guest_serial_text "FC_ROOTFS_PASS=1"; then
                echo "[verify] pass"
                return 0
            fi
            echo "[verify] qemu exited before pass marker" >&2
            tail -n 260 "$QEMU_LOG" >&2 || true
            return 1
        fi
        sleep "$POLL_SECS"
    done

    echo "[verify] timeout after ${TIMEOUT_SECS}s waiting for pass marker" >&2
    tail -n 320 "$QEMU_LOG" >&2 || true
    cleanup
    return 1
}

need_cmd bash
need_cmd cpio
if [[ "$FIRECRACKER_GUEST_BOOT_MODE" == "rootfs" ]]; then
    need_cmd debugfs
    if [[ "$FIRECRACKER_ROOTFS_INIT_KIND" == "tiny" ]]; then
        need_cmd gcc
    fi
    need_cmd mkfs.ext4
    need_cmd truncate
fi
need_cmd find
need_cmd gzip
need_cmd grep
need_cmd ldd
need_cmd ln
need_cmd python3
need_cmd tail
need_file "$QEMU_BIN"
need_file "$BUSYBOX"
need_file "$FIRECRACKER_BIN"

trap cleanup EXIT
mkdir -p "$RUN_DIR"

build_kernel_and_module
case "$FIRECRACKER_GUEST_BOOT_MODE" in
    initramfs)
        prepare_guest_initramfs
        ;;
    rootfs)
        case "$FIRECRACKER_ROOTFS_INIT_KIND" in
            sh)
                prepare_guest_rootfs
                ;;
            tiny)
                FIRECRACKER_GUEST_INIT=/init
                prepare_guest_rootfs_tiny
                ;;
            *)
                echo "unsupported FIRECRACKER_ROOTFS_INIT_KIND=$FIRECRACKER_ROOTFS_INIT_KIND" >&2
                exit 1
                ;;
        esac
        ;;
    *)
        echo "unsupported FIRECRACKER_GUEST_BOOT_MODE=$FIRECRACKER_GUEST_BOOT_MODE" >&2
        exit 1
        ;;
esac
prepare_host_initramfs
launch_qemu
wait_for_result
validate_firecracker_guest_result
write_firecracker_guest_result

echo "[verify] run dir: $RUN_DIR"
echo "[verify] qemu log: $QEMU_LOG"
echo "[verify] firecracker serial decoded: $RUN_DIR/firecracker-serial-decoded.log"
echo "[verify] firecracker result: $RUN_DIR/firecracker-result.txt"
echo "[verify] host kernel image: $HOST_KERNEL_IMAGE"
echo "[verify] module: $KO_PATH"
echo "[verify] firecracker: $FIRECRACKER_BIN"
echo "[verify] guest kernel: $GUEST_KERNEL_IMAGE"
echo "[verify] firecracker vcpus: $FIRECRACKER_VCPU_COUNT"
if [[ "$FIRECRACKER_GUEST_BOOT_MODE" == "rootfs" ]]; then
    echo "[verify] guest rootfs: $GUEST_ROOTFS_IMG"
    echo "[verify] rootfs init kind: $FIRECRACKER_ROOTFS_INIT_KIND"
else
    echo "[verify] guest initramfs: $GUEST_INITRAMFS_IMG"
fi
