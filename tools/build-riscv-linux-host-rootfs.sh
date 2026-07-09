#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

ROOT_TAR="${ROOT_TAR:-/tmp/ubuntu-riscv64-root.tar.xz}"
ROOTFS_IMG="${ROOTFS_IMG:-/tmp/axvisor-riscv64-host-rootfs.img}"
ROOTFS_SIZE_GB="${ROOTFS_SIZE_GB:-4}"
STAGING_DIR="${STAGING_DIR:-/tmp/axvisor-riscv64-rootfs-staging}"
MOUNT_DIR="${MOUNT_DIR:-/tmp/axvisor-riscv64-rootfs-mnt}"
DEFAULT_MODULE_KO_O="$ROOT_DIR/linux-host-kernel/build-axvisor/drivers/virt/axvisor/axvisor_adapter.ko"
DEFAULT_MODULE_KO_IN_TREE="$ROOT_DIR/linux-host-kernel/drivers/virt/axvisor/axvisor_adapter.ko"
MODULE_KO="${MODULE_KO:-$DEFAULT_MODULE_KO_O}"
QEMU_SCRIPT="${QEMU_SCRIPT:-$ROOT_DIR/tools/run-riscv-linux-host-qemu.sh}"
GUEST_KIND="${GUEST_KIND:-linux}"
case "$GUEST_KIND" in
    linux)
        DEFAULT_GUEST_ROOTFS="$ROOT_DIR/ivans-asterinas-axvisor-host/target/axvisor/images/qemu_riscv64_linux/rootfs.img"
        DEFAULT_VM_NAME="linux-qemu"
        ;;
    arceos)
        DEFAULT_GUEST_ROOTFS="$ROOT_DIR/ivans-asterinas-axvisor-host/target/axvisor/images/qemu_riscv64_arceos/rootfs.img"
        DEFAULT_VM_NAME="arceos-qemu"
        ;;
    *)
        echo "unsupported GUEST_KIND: $GUEST_KIND" >&2
        echo "expected one of: linux, arceos" >&2
        exit 1
        ;;
esac
GUEST_ROOTFS="${GUEST_ROOTFS:-$DEFAULT_GUEST_ROOTFS}"
GUEST_LINUX_BOOT_MODE="${GUEST_LINUX_BOOT_MODE:-getty}"
GUEST_LINUX_CMDLINE="${GUEST_LINUX_CMDLINE:-}"
GUEST_LINUX_GETTY_INIT_PATH="${GUEST_LINUX_GETTY_INIT_PATH:-/init}"
GUEST_LINUX_SMOKE_INIT_PATH="${GUEST_LINUX_SMOKE_INIT_PATH:-/init}"
DEFAULT_HOST_DTB="$ROOT_DIR/tools/qemu-riscv64-virt-host.dtb"
DEFAULT_HOST_BOOT_DTB="$ROOT_DIR/tools/qemu-riscv64-virt-host-boot.dtb"
HOST_DTB="${HOST_DTB:-}"
AXVISOR_GUEST_RAM_BASE="${AXVISOR_GUEST_RAM_BASE:-0x90000000}"
AXVISOR_GUEST_RAM_SIZE="${AXVISOR_GUEST_RAM_SIZE:-0x40000000}"
AXVISOR_INJECT_RESERVED_MEMORY="${AXVISOR_INJECT_RESERVED_MEMORY:-1}"
ENABLE_AXVISOR_AUTOBOOT="${ENABLE_AXVISOR_AUTOBOOT:-0}"
AXVISOR_AUTOBOOT_DELAY_SECS="${AXVISOR_AUTOBOOT_DELAY_SECS:-20}"
AXVISOR_AUTOBOOT_SYNC_TIMEOUT_SECS="${AXVISOR_AUTOBOOT_SYNC_TIMEOUT_SECS:-5}"
AXVISOR_PASSTHROUGH_SETTLE_TIMEOUT_SECS="${AXVISOR_PASSTHROUGH_SETTLE_TIMEOUT_SECS:-15}"
AXVISOR_CAPTURE_GUEST_CONSOLE="${AXVISOR_CAPTURE_GUEST_CONSOLE:-0}"
AXVISOR_GUEST_CONSOLE_CAPTURE_TIMEOUT="${AXVISOR_GUEST_CONSOLE_CAPTURE_TIMEOUT:-45}"
if [[ -z "${ENABLE_SERIAL_GETTY+x}" ]]; then
    if [[ "$ENABLE_AXVISOR_AUTOBOOT" == "1" ]]; then
        ENABLE_SERIAL_GETTY=0
    else
        ENABLE_SERIAL_GETTY=1
    fi
fi

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "missing command: $1" >&2
        exit 1
    }
}

DEBUGFS_CMDS=""

copy_tree_with_debugfs() {
    local src_root="$1"
    local image="$2"
    local entry rel link_target
    local -a dirs files symlinks

    DEBUGFS_CMDS="$(mktemp /tmp/axvisor-debugfs.XXXXXX)"
    trap 'rm -f "$DEBUGFS_CMDS"; cleanup' EXIT

    while IFS= read -r -d '' entry; do
        rel="${entry#"$src_root"/}"
        [[ "$rel" == "$entry" ]] && continue

        if [[ -L "$entry" ]]; then
            symlinks+=("$rel")
        else
            if [[ -d "$entry" ]]; then
                dirs+=("$rel")
                continue
            fi

            files+=("$rel")
        fi
    done < <(find "$src_root" -mindepth 1 -print0 | sort -z)

    for rel in "${dirs[@]}"; do
        printf 'mkdir "/%s"\n' "$rel" >>"$DEBUGFS_CMDS"
    done

    for rel in "${files[@]}"; do
        printf 'write "%s/%s" "/%s"\n' "$src_root" "$rel" "$rel" >>"$DEBUGFS_CMDS"
    done

    for rel in "${symlinks[@]}"; do
        link_target="$(readlink "$src_root/$rel")"
        printf 'symlink "/%s" "%s"\n' "$rel" "$link_target" >>"$DEBUGFS_CMDS"
    done

    if ! debugfs -w -f "$DEBUGFS_CMDS" "$image"; then
        echo "failed to populate rootfs image with debugfs" >&2
        return 1
    fi
}

need_cmd tar
need_cmd truncate
need_cmd mkfs.ext4
need_cmd debugfs
if [[ "$GUEST_KIND" == "linux" ]]; then
    need_cmd gzip
    need_cmd cpio
fi

build_boot_dtb() {
    local src_dtb="$1"
    local dst_dtb="$2"
    local dts_tmp

    need_cmd dtc
    need_cmd python3

    dts_tmp="$(mktemp /tmp/axvisor-riscv64-host-boot-dtb.XXXXXX.dts)"
    trap 'rm -f "$dts_tmp"' RETURN

    dtc -I dtb -O dts -o "$dts_tmp" "$src_dtb"

    python3 - "$dts_tmp" "$AXVISOR_GUEST_RAM_BASE" "$AXVISOR_GUEST_RAM_SIZE" <<'PY'
import pathlib
import sys

dts_path = pathlib.Path(sys.argv[1])
base = int(sys.argv[2], 0)
size = int(sys.argv[3], 0)
text = dts_path.read_text()

node = f"""
\treserved-memory {{
\t\t#address-cells = <0x02>;
\t\t#size-cells = <0x02>;
\t\tranges;

\t\taxvisor_guest_ram@{base:x} {{
\t\t\treg = <0x0 0x{base:08x} 0x0 0x{size:08x}>;
\t\t\tno-map;
\t\t}};
\t}};
"""

start = text.find("/ {")
if start < 0:
    raise SystemExit("failed to find root node in host DTB source")
insert_at = text.find("\n};", start)
if insert_at < 0:
    raise SystemExit("failed to find root node terminator in host DTB source")

if "axvisor_guest_ram@" in text:
    raise SystemExit("host DTB source already contains axvisor_guest_ram reserved-memory node")

text = text[:insert_at] + node + text[insert_at:]
dts_path.write_text(text)
PY

    dtc -I dts -O dtb -o "$dst_dtb" "$dts_tmp"
    rm -f "$dts_tmp"
    trap - RETURN
}

linux_guest_cmdline() {
    if [[ -n "$GUEST_LINUX_CMDLINE" ]]; then
        printf '%s' "$GUEST_LINUX_CMDLINE"
        return 0
    fi

    case "$GUEST_LINUX_BOOT_MODE" in
        getty)
            printf '%s' \
                "earlycon=sbi console=ttyS0,115200 root=/dev/vda rw rootwait devtmpfs.mount=1 init=$GUEST_LINUX_GETTY_INIT_PATH"
            ;;
        smoke)
            printf '%s' \
                "earlycon=sbi console=ttyS0,115200 root=/dev/vda rw rootwait devtmpfs.mount=1 init=$GUEST_LINUX_SMOKE_INIT_PATH"
            ;;
        *)
            echo "unsupported GUEST_LINUX_BOOT_MODE: $GUEST_LINUX_BOOT_MODE" >&2
            return 1
            ;;
    esac
}

if [[ -z "$HOST_DTB" ]]; then
    if [[ "$AXVISOR_INJECT_RESERVED_MEMORY" == "1" && -f "$DEFAULT_HOST_DTB" ]]; then
        build_boot_dtb "$DEFAULT_HOST_DTB" "$DEFAULT_HOST_BOOT_DTB"
        HOST_DTB="$DEFAULT_HOST_BOOT_DTB"
    elif [[ -f "$DEFAULT_HOST_BOOT_DTB" ]]; then
        HOST_DTB="$DEFAULT_HOST_BOOT_DTB"
    else
        HOST_DTB="$DEFAULT_HOST_DTB"
    fi
fi

SUDO_AVAILABLE=0
if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    need_cmd mount
    need_cmd umount
    SUDO_AVAILABLE=1
fi

if [[ ! -f "$MODULE_KO" ]]; then
    if [[ "$MODULE_KO" == "$DEFAULT_MODULE_KO_O" && -f "$DEFAULT_MODULE_KO_IN_TREE" ]]; then
        MODULE_KO="$DEFAULT_MODULE_KO_IN_TREE"
    else
        echo "axvisor module not found: $MODULE_KO" >&2
        echo "expected built module at: $DEFAULT_MODULE_KO_O" >&2
        echo "build it with:" >&2
        echo "  make O=$ROOT_DIR/linux-host-kernel/build-axvisor drivers/virt/axvisor/axvisor_adapter.ko" >&2
        exit 1
    fi
fi

if [[ "$MODULE_KO" -ot "$ROOT_DIR/linux-host-kernel/drivers/virt/axvisor/axvisor_adapter_shim.c" || \
      "$MODULE_KO" -ot "$ROOT_DIR/linux-host-kernel/drivers/virt/axvisor/axvisor_adapter_main.rs" || \
      "$MODULE_KO" -ot "$ROOT_DIR/linux-host-kernel/drivers/virt/axvisor/vendor/upstream/axvm/src/vm.rs" || \
      "$MODULE_KO" -ot "$ROOT_DIR/linux-host-kernel/drivers/virt/axvisor/vendor/upstream/axvisor_linux_bridge/src/lib.rs" ]]; then
    echo "axvisor module is older than source changes: $MODULE_KO" >&2
    echo "rebuild it first with:" >&2
    echo "  bash $ROOT_DIR/tools/build-riscv-linux-host-module.sh" >&2
    exit 1
fi

if [[ ! -f "$ROOT_TAR" ]]; then
    echo "rootfs tarball not found: $ROOT_TAR" >&2
    exit 1
fi

mkdir -p "$STAGING_DIR" "$MOUNT_DIR"
rm -rf "$STAGING_DIR"/*

echo "[1/6] extracting rootfs tarball to staging"
tar \
    -xJf "$ROOT_TAR" \
    -C "$STAGING_DIR" \
    --exclude='dev'
rm -rf "$STAGING_DIR/dev"

mkdir -p "$STAGING_DIR/dev" "$STAGING_DIR/proc" "$STAGING_DIR/sys" "$STAGING_DIR/run" "$STAGING_DIR/tmp"
chmod 1777 "$STAGING_DIR/tmp"

echo "[2/6] preparing guest-side helper files"
mkdir -p \
    "$STAGING_DIR/root/axvisor" \
    "$STAGING_DIR/guest" \
    "$STAGING_DIR/etc/systemd/system/serial-getty@ttyS0.service.d" \
    "$STAGING_DIR/etc/systemd/system/multi-user.target.wants"

cp "$MODULE_KO" "$STAGING_DIR/root/axvisor/"

if [[ -f "$GUEST_ROOTFS" ]]; then
    cp "$GUEST_ROOTFS" "$STAGING_DIR/guest/rootfs.img"
else
    echo "warning: guest rootfs image not found: $GUEST_ROOTFS" >&2
fi

if [[ -f "$HOST_DTB" ]]; then
    cp "$HOST_DTB" "$STAGING_DIR/root/axvisor/host-qemu-virt.dtb"
else
    echo "warning: host DTB not found: $HOST_DTB" >&2
fi

cat >"$STAGING_DIR/root/axvisor/load-axvisor.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

KO_PATH="${1:-/root/axvisor/axvisor_adapter.ko}"
HOST_DTB_PATH="${HOST_DTB_PATH:-/root/axvisor/host-qemu-virt.dtb}"
READY_TIMEOUT="${AXVISOR_READY_TIMEOUT:-90}"
RELEASE_REGISTERED_MMIO="${AXVISOR_RELEASE_REGISTERED_PASSTHROUGH_MMIO:-0}"
RELEASE_MMIO_PADDRS="${AXVISOR_RELEASE_MMIO_PADDRS:-}"

insmod_args=()

if [[ ! -f "$KO_PATH" ]]; then
    echo "axvisor module not found: $KO_PATH" >&2
    exit 1
fi

echo "[guest] uname -a"
uname -a
if [[ -f "$HOST_DTB_PATH" ]]; then
    insmod_args+=("host_fdt_path=$HOST_DTB_PATH")
fi
if [[ "$RELEASE_REGISTERED_MMIO" == "1" ]]; then
    insmod_args+=("release_registered_passthrough_mmio=1")
fi
if [[ -n "$RELEASE_MMIO_PADDRS" ]]; then
    insmod_args+=("release_mmio_paddrs=$RELEASE_MMIO_PADDRS")
fi
if ((${#insmod_args[@]})); then
    echo "[guest] insmod $KO_PATH ${insmod_args[*]}"
    insmod "$KO_PATH" "${insmod_args[@]}"
else
    echo "[guest] insmod $KO_PATH"
    insmod "$KO_PATH"
fi
echo "[guest] waiting for AxVisor shell ready"
AXVISOR_SHELL_READY=0
for _ in $(seq 1 "$READY_TIMEOUT"); do
    if [[ -e /proc/axvisor_shell ]] && printf 'vm list\n' > /proc/axvisor_shell 2>/dev/null; then
        echo "[guest] AxVisor shell ready"
        AXVISOR_SHELL_READY=1
        break
    fi
    sleep 1
done
if [[ "$AXVISOR_SHELL_READY" != "1" ]]; then
    echo "[guest] AxVisor shell not ready after ${READY_TIMEOUT}s" >&2
    dmesg | tail -n 260
    exit 1
fi
echo "[guest] dmesg | tail -n 200"
dmesg | tail -n 200
EOF
chmod +x "$STAGING_DIR/root/axvisor/load-axvisor.sh"

cat >"$STAGING_DIR/root/axvisor/auto-start-axvisor.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LOG_PATH="/root/axvisor/autostart.log"
exec >>"$LOG_PATH" 2>&1

log_guest_auto() {
    local msg="$1"
    echo "[guest-auto] $(date -Ins) $msg"
    if [[ -e /dev/console ]]; then
        printf 'axvisor-autoboot:%s\n' "$msg" > /dev/console 2>/dev/null || true
    fi
    if [[ -e /dev/kmsg ]]; then
        printf '<6>axvisor-autoboot:%s\n' "$msg" > /dev/kmsg 2>/dev/null || true
    fi
}

log_guest_auto "begin"
/root/axvisor/load-axvisor.sh
log_guest_auto "saving prestart dmesg"
if ! dmesg > /root/axvisor/prestart-dmesg.log 2>/dev/null; then
    log_guest_auto "failed to save prestart dmesg"
fi
log_guest_auto "prestart dmesg grep"
if ! grep -E "vmm::init stage|release_host_filesystems|passthrough device register|requested passthrough irq|skip host request_irq|releasing platform MMIO device|virtio-mmio handoff reset|external_irq|plic claim|passthrough irq inject|Host filesystem cleanly unmounted" \
    /root/axvisor/prestart-dmesg.log > /root/axvisor/prestart-dmesg.grep 2>/dev/null; then
    log_guest_auto "prestart dmesg grep found no matches"
fi
for _ in $(seq 1 60); do
    if [[ -e /proc/axvisor_shell ]]; then
        break
    fi
    sleep 1
done
if ! [[ -e /proc/axvisor_shell ]]; then
    log_guest_auto "/proc/axvisor_shell not present"
    dmesg | tail -n 220
    exit 1
fi
log_guest_auto "/proc/axvisor_shell present"
log_guest_auto "sync host state"
# File-scoped sync on the active rootfs can block indefinitely on this host path.
# A bounded global sync is sufficient for flushing prior log/module writes.
if ! timeout "${AXVISOR_AUTOBOOT_SYNC_TIMEOUT_SECS:-5}" sync; then
    log_guest_auto "sync host state skipped after timeout=${AXVISOR_AUTOBOOT_SYNC_TIMEOUT_SECS:-5}s"
fi
if command -v udevadm >/dev/null 2>&1; then
    log_guest_auto "udevadm settle"
    if ! timeout "${AXVISOR_PASSTHROUGH_SETTLE_TIMEOUT_SECS:-15}" udevadm settle; then
        log_guest_auto "udevadm settle timed out after ${AXVISOR_PASSTHROUGH_SETTLE_TIMEOUT_SECS:-15}s"
    fi
fi
log_guest_auto "waiting for guest rootfs handoff"
handoff_targets=(
    /dev/vda
    /sys/block/vda
    /sys/bus/virtio/devices/virtio0
    /sys/bus/virtio/drivers/virtio_blk/virtio0
    /sys/bus/platform/devices/10008000.virtio_mmio/driver
)
handoff_ready=0
for _ in $(seq 1 "${AXVISOR_PASSTHROUGH_SETTLE_TIMEOUT_SECS:-15}"); do
    remaining=()
    for path in "${handoff_targets[@]}"; do
        if [[ -e "$path" ]]; then
            remaining+=("$path")
        fi
    done
    if ((${#remaining[@]} == 0)); then
        handoff_ready=1
        break
    fi
    log_guest_auto "waiting paths=${remaining[*]}"
    sleep 1
done
if [[ "$handoff_ready" == "1" ]]; then
    log_guest_auto "guest rootfs handoff ready"
else
    log_guest_auto "guest rootfs handoff timeout after ${AXVISOR_PASSTHROUGH_SETTLE_TIMEOUT_SECS:-15}s"
fi
sleep 1
if [[ "${AXVISOR_CAPTURE_GUEST_CONSOLE:-0}" == "1" ]]; then
    log_guest_auto "starting guest console capture"
    rm -f /root/axvisor/guest-console.log
    GUEST_CONSOLE_CAPTURE_PID=""
    if [[ -e /proc/axvisor_guest_console ]]; then
        timeout "${AXVISOR_GUEST_CONSOLE_CAPTURE_TIMEOUT:-45}" \
            bash -c '
                if [[ -e /dev/console ]]; then
                    cat /proc/axvisor_guest_console \
                        | tee /root/axvisor/guest-console.log > /dev/console
                else
                    cat /proc/axvisor_guest_console > /root/axvisor/guest-console.log
                fi
            ' &
        GUEST_CONSOLE_CAPTURE_PID=$!
    else
        log_guest_auto "/proc/axvisor_guest_console not present"
    fi
fi
log_guest_auto "vm start 1"
for attempt in $(seq 1 10); do
    if timeout 5 bash -c "printf 'vm start 1\n' > /proc/axvisor_shell"; then
        log_guest_auto "vm start 1 written attempt=$attempt"
        break
    fi
    rc=$?
    log_guest_auto "vm start write failed attempt=$attempt rc=$rc"
    sleep 1
done
sleep 2
if [[ -n "${GUEST_CONSOLE_CAPTURE_PID:-}" ]]; then
    log_guest_auto "waiting for guest console capture pid=$GUEST_CONSOLE_CAPTURE_PID"
    wait "$GUEST_CONSOLE_CAPTURE_PID" || true
    log_guest_auto "guest console capture bytes=$(wc -c < /root/axvisor/guest-console.log 2>/dev/null || echo 0)"
fi
log_guest_auto "dmesg | tail -n 260"
if ! timeout 10 bash -c 'dmesg | tail -n 260'; then
    log_guest_auto "dmesg tail timed out"
fi
log_guest_auto "saving poststart dmesg"
if ! dmesg > /root/axvisor/poststart-dmesg.log 2>/dev/null; then
    log_guest_auto "failed to save poststart dmesg"
fi
log_guest_auto "end"
EOF
chmod +x "$STAGING_DIR/root/axvisor/auto-start-axvisor.sh"

cat >"$STAGING_DIR/etc/systemd/system/axvisor-autoboot.service" <<EOF
[Unit]
Description=Auto load AxVisor and start bundled VM
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=AXVISOR_CAPTURE_GUEST_CONSOLE=$AXVISOR_CAPTURE_GUEST_CONSOLE
Environment=AXVISOR_GUEST_CONSOLE_CAPTURE_TIMEOUT=$AXVISOR_GUEST_CONSOLE_CAPTURE_TIMEOUT
Environment=AXVISOR_AUTOBOOT_SYNC_TIMEOUT_SECS=$AXVISOR_AUTOBOOT_SYNC_TIMEOUT_SECS
Environment=AXVISOR_PASSTHROUGH_SETTLE_TIMEOUT_SECS=$AXVISOR_PASSTHROUGH_SETTLE_TIMEOUT_SECS
Environment=AXVISOR_RELEASE_REGISTERED_PASSTHROUGH_MMIO=${AXVISOR_RELEASE_REGISTERED_PASSTHROUGH_MMIO:-0}
Environment=AXVISOR_RELEASE_MMIO_PADDRS=${AXVISOR_RELEASE_MMIO_PADDRS:-}
ExecStart=/root/axvisor/auto-start-axvisor.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=axvisor-autoboot.timer
EOF

cat >"$STAGING_DIR/etc/systemd/system/axvisor-autoboot.timer" <<EOF
[Unit]
Description=Delayed AxVisor autoboot trigger
After=multi-user.target

[Timer]
OnBootSec=${AXVISOR_AUTOBOOT_DELAY_SECS}s
Unit=axvisor-autoboot.service

[Install]
WantedBy=timers.target
EOF

if [[ "$ENABLE_AXVISOR_AUTOBOOT" == "1" ]]; then
    ln -sf /etc/systemd/system/axvisor-autoboot.timer \
        "$STAGING_DIR/etc/systemd/system/timers.target.wants/axvisor-autoboot.timer"
fi

cat >"$STAGING_DIR/root/axvisor/README.txt" <<EOF
Inside the guest:

  /root/axvisor/load-axvisor.sh

If you need to load the module manually:

  insmod /root/axvisor/axvisor_adapter.ko
  dmesg | tail -n 200

If the host has already moved its own console off UART and you want the guest
to take ownership of passthrough MMIO devices such as ttyS0/virtio-mmio:

  AXVISOR_RELEASE_REGISTERED_PASSTHROUGH_MMIO=1 /root/axvisor/load-axvisor.sh

Or explicitly release selected platform MMIO base addresses:

  AXVISOR_RELEASE_MMIO_PADDRS=0x10000000,0x10008000 /root/axvisor/load-axvisor.sh

After \`load-axvisor.sh\`, AxVisor creates VM definitions from the static VM
configuration and images embedded in \`axvisor_adapter.ko\`.

Current guest kind:

  $GUEST_KIND

To inspect and start the bundled RISC-V guest:

  printf 'vm list\n' > /proc/axvisor_shell
  printf 'vm start 1\n' > /proc/axvisor_shell

Autoboot service:

  disabled by default
  enable at image build time with:
  ENABLE_AXVISOR_AUTOBOOT=1 GUEST_KIND=$GUEST_KIND bash tools/build-riscv-linux-host-rootfs.sh
  default boot delay: ${AXVISOR_AUTOBOOT_DELAY_SECS}s

Host helper script:

  $QEMU_SCRIPT
EOF

cat >"$STAGING_DIR/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200,57600,38400,9600 ttyS0 vt220
EOF

if [[ "$ENABLE_SERIAL_GETTY" == "1" ]]; then
    ln -sf /lib/systemd/system/serial-getty@.service \
        "$STAGING_DIR/etc/systemd/system/multi-user.target.wants/serial-getty@ttyS0.service"
fi

echo "[3/6] creating ext4 image: $ROOTFS_IMG"
rm -f "$ROOTFS_IMG"
truncate -s "${ROOTFS_SIZE_GB}G" "$ROOTFS_IMG"
mkfs.ext4 -F "$ROOTFS_IMG" >/dev/null

cleanup() {
    if (( SUDO_AVAILABLE )) && mountpoint -q "$MOUNT_DIR"; then
        sudo umount "$MOUNT_DIR"
    fi
}
trap cleanup EXIT

if (( SUDO_AVAILABLE )); then
    echo "[4/6] mounting rootfs image"
    sudo mount -o loop "$ROOTFS_IMG" "$MOUNT_DIR"

    echo "[5/6] copying staged rootfs into image"
    sudo rm -rf "$MOUNT_DIR"/*
    sudo cp -a "$STAGING_DIR"/. "$MOUNT_DIR"/
    sudo sync
else
    echo "[4/6] populating rootfs image with debugfs (sudo-free path)"
    echo "[5/6] copying staged rootfs into image"
    copy_tree_with_debugfs "$STAGING_DIR" "$ROOTFS_IMG"
fi

echo "[6/6] done"
echo "rootfs image: $ROOTFS_IMG"
echo "guest helper: /root/axvisor/load-axvisor.sh"
