#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

BASE_GUEST_ROOTFS_IMG="${BASE_GUEST_ROOTFS_IMG:-$ROOT_DIR/ivans-asterinas-axvisor-host/target/axvisor/images/qemu_riscv64_linux/rootfs.img}"
GETTY_INIT_TEMPLATE="${GETTY_INIT_TEMPLATE:-$ROOT_DIR/tools/axvisor-guest-linux-getty-init.sh}"
GETTY_INIT_PATH_IN_GUEST="${GETTY_INIT_PATH_IN_GUEST:-/init}"
GETTY_GUEST_ROOTFS_IMG="${GETTY_GUEST_ROOTFS_IMG:-/tmp/axvisor-qemu-riscv64-linux-guest-rootfs-getty.img}"

need_file() {
    [[ -f "$1" ]] || {
        echo "required file not found: $1" >&2
        exit 1
    }
}

need_file "$BASE_GUEST_ROOTFS_IMG"
need_file "$GETTY_INIT_TEMPLATE"
if [[ ! -x "$GETTY_INIT_TEMPLATE" ]]; then
    echo "getty init template must be executable: $GETTY_INIT_TEMPLATE" >&2
    exit 1
fi
command -v debugfs >/dev/null 2>&1 || {
    echo "missing command: debugfs" >&2
    exit 1
}

cp "$BASE_GUEST_ROOTFS_IMG" "$GETTY_GUEST_ROOTFS_IMG"
debugfs -w -R "rm $GETTY_INIT_PATH_IN_GUEST" \
    "$GETTY_GUEST_ROOTFS_IMG" >/dev/null
debugfs -w -R "write $GETTY_INIT_TEMPLATE $GETTY_INIT_PATH_IN_GUEST" \
    "$GETTY_GUEST_ROOTFS_IMG" >/dev/null

echo "$GETTY_GUEST_ROOTFS_IMG"
