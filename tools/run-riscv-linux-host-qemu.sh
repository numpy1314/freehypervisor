#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

QEMU_BIN="${QEMU_BIN:-/home/bullet1517/qemu-9.2.4/build/qemu-system-riscv64}"
OPENSBI_BIN="${OPENSBI_BIN:-/home/bullet1517/qemu-9.2.4/pc-bios/opensbi-riscv64-generic-fw_dynamic.bin}"
KERNEL_IMAGE="${KERNEL_IMAGE:-$ROOT_DIR/linux-host-kernel/build-axvisor/arch/riscv/boot/Image}"
ROOTFS_IMG="${ROOTFS_IMG:-/tmp/axvisor-riscv64-host-rootfs.img}"
GUEST_ROOTFS_IMG="${GUEST_ROOTFS_IMG:-$ROOT_DIR/ivans-asterinas-axvisor-host/target/axvisor/images/qemu_riscv64_linux/rootfs.img}"
MEMORY_MB="${MEMORY_MB:-4096}"
SMP_CPUS="${SMP_CPUS:-1}"
QEMU_LOG="${QEMU_LOG:-/tmp/axvisor-riscv64-host-qemu.log}"
HOST_HVC_LOG="${HOST_HVC_LOG:-/tmp/axvisor-riscv64-host-hvc.log}"
HOST_DTB_OUT="${HOST_DTB_OUT:-$ROOT_DIR/tools/qemu-riscv64-virt-host.dtb}"
BOOT_DTB_OUT="${BOOT_DTB_OUT:-$ROOT_DIR/tools/qemu-riscv64-virt-host-boot.dtb}"
AXVISOR_GUEST_RAM_BASE="${AXVISOR_GUEST_RAM_BASE:-0x90000000}"
AXVISOR_GUEST_RAM_SIZE="${AXVISOR_GUEST_RAM_SIZE:-0x40000000}"
AXVISOR_INJECT_RESERVED_MEMORY="${AXVISOR_INJECT_RESERVED_MEMORY:-1}"
QEMU_CPU="${QEMU_CPU:-rv64,h=true,svpbmt=true}"
HOST_CONSOLE_MODE="${HOST_CONSOLE_MODE:-serial}"
if [[ -z "${HOST_DISABLE_UART_NODE+x}" ]]; then
    if [[ "$HOST_CONSOLE_MODE" == "hvc0" ]]; then
        HOST_DISABLE_UART_NODE=1
    else
        HOST_DISABLE_UART_NODE=0
    fi
fi
if [[ -z "${KERNEL_APPEND:-}" ]]; then
    case "$HOST_CONSOLE_MODE" in
        serial)
            KERNEL_APPEND='root=/dev/vdb rw rootwait console=ttyS0 earlycon=sbi loglevel=8'
            ;;
        hvc0)
            KERNEL_APPEND='root=/dev/vdb rw rootwait console=hvc0 earlycon=sbi loglevel=8'
            ;;
        *)
            echo "unsupported HOST_CONSOLE_MODE: $HOST_CONSOLE_MODE" >&2
            exit 1
            ;;
    esac
fi

need_file() {
    [[ -f "$1" ]] || {
        echo "required file not found: $1" >&2
        exit 1
    }
}

need_file "$QEMU_BIN"
need_file "$OPENSBI_BIN"
need_file "$KERNEL_IMAGE"
need_file "$ROOTFS_IMG"
need_file "$GUEST_ROOTFS_IMG"

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "missing command: $1" >&2
        exit 1
    }
}

build_boot_dtb() {
    local src_dtb="$1"
    local dst_dtb="$2"
    local dts_tmp

    need_cmd dtc

    dts_tmp="$(mktemp /tmp/axvisor-riscv64-host-boot-dtb.XXXXXX.dts)"
    trap 'rm -f "$dts_tmp"' RETURN

    dtc -I dtb -O dts -o "$dts_tmp" "$src_dtb"

    python3 - "$dts_tmp" "$AXVISOR_GUEST_RAM_BASE" "$AXVISOR_GUEST_RAM_SIZE" "$HOST_DISABLE_UART_NODE" <<'PY'
import pathlib
import re
import sys

dts_path = pathlib.Path(sys.argv[1])
base = int(sys.argv[2], 0)
size = int(sys.argv[3], 0)
disable_uart = int(sys.argv[4], 0) != 0
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

if disable_uart:
    serial_pat = re.compile(r'(\n\s*serial@10000000\s*\{\n)(.*?)(\n\s*\};)', re.DOTALL)
    match = serial_pat.search(text)
    if not match:
        raise SystemExit("failed to disable /soc/serial@10000000 in host DTB source")
    body = match.group(2)
    if 'status = "disabled";' not in body:
        body = body + '\t\t\tstatus = "disabled";\n'
    text = text[:match.start()] + match.group(1) + body + match.group(3) + text[match.end():]

dts_path.write_text(text)
PY

    dtc -I dts -O dtb -o "$dst_dtb" "$dts_tmp"
    rm -f "$dts_tmp"
    trap - RETURN
}

DTB_ARGS=()
if [[ "$AXVISOR_INJECT_RESERVED_MEMORY" == "1" && -f "$HOST_DTB_OUT" ]]; then
    build_boot_dtb "$HOST_DTB_OUT" "$BOOT_DTB_OUT"
    DTB_ARGS=(-dtb "$BOOT_DTB_OUT")
fi

QEMU_CONSOLE_ARGS=()
case "$HOST_CONSOLE_MODE" in
    serial)
        QEMU_CONSOLE_ARGS=(
            -chardev stdio,id=stdio,mux=on,signal=off,logfile="$QEMU_LOG"
            -serial chardev:stdio
            -monitor chardev:stdio
        )
        ;;
    hvc0)
        rm -f "$HOST_HVC_LOG"
        QEMU_CONSOLE_ARGS=(
            -device virtio-serial-device
            -chardev file,id=host_hvc,path="$HOST_HVC_LOG"
            -device virtconsole,chardev=host_hvc
            -chardev stdio,id=stdio,mux=on,signal=off,logfile="$QEMU_LOG"
            -serial chardev:stdio
            -monitor chardev:stdio
        )
        ;;
    *)
        echo "unsupported HOST_CONSOLE_MODE: $HOST_CONSOLE_MODE" >&2
        exit 1
        ;;
esac

exec "$QEMU_BIN" \
    -machine virt \
    -cpu "$QEMU_CPU" \
    -m "$MEMORY_MB" \
    -smp "$SMP_CPUS" \
    -nographic \
    -bios "$OPENSBI_BIN" \
    "${DTB_ARGS[@]}" \
    -kernel "$KERNEL_IMAGE" \
    -append "$KERNEL_APPEND" \
    -device virtio-blk-device,drive=guest_rootfs \
    -drive if=none,format=raw,id=guest_rootfs,file="$GUEST_ROOTFS_IMG" \
    -device virtio-blk-device,drive=host_rootfs \
    -drive if=none,format=raw,id=host_rootfs,file="$ROOTFS_IMG" \
    "${QEMU_CONSOLE_ARGS[@]}"
