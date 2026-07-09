#!/usr/bin/env bash
set -euo pipefail

ROOTFS_TAR="${ROOTFS_TAR:-/tmp/ubuntu-riscv64-root.tar.xz}"
WORK_DIR="${WORK_DIR:-/tmp/ubuntu-riscv64-rootfs-build}"
ROOTFS_DIR="${ROOTFS_DIR:-$WORK_DIR/rootfs}"
UBUNTU_RELEASE="${UBUNTU_RELEASE:-noble}"
UBUNTU_MIRROR="${UBUNTU_MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"

PACKAGES="${PACKAGES:-\
systemd-sysv,\
kmod,\
udev,\
iproute2,\
iputils-ping,\
net-tools,\
openssh-server,\
sudo,\
vim-tiny,\
less,\
ca-certificates}"

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "missing command: $1" >&2
        exit 1
    }
}

need_cmd sudo
need_cmd qemu-debootstrap
need_cmd tar

sudo rm -rf "$ROOTFS_DIR"
mkdir -p "$WORK_DIR"

echo "[1/5] debootstrap riscv64 ubuntu rootfs into $ROOTFS_DIR"
sudo qemu-debootstrap \
    --arch=riscv64 \
    --include="$PACKAGES" \
    "$UBUNTU_RELEASE" \
    "$ROOTFS_DIR" \
    "$UBUNTU_MIRROR"

echo "[2/5] configuring guest defaults"
echo ubuntu | sudo tee "$ROOTFS_DIR/etc/hostname" >/dev/null
cat <<'EOF' | sudo tee "$ROOTFS_DIR/etc/hosts" >/dev/null
127.0.0.1 localhost
127.0.1.1 ubuntu
::1 localhost ip6-localhost ip6-loopback
EOF

cat <<'EOF' | sudo tee "$ROOTFS_DIR/etc/systemd/network/20-wired.network" >/dev/null
[Match]
Name=en*
Name=eth0

[Network]
DHCP=yes
EOF

echo "root:root" | sudo chroot "$ROOTFS_DIR" chpasswd
sudo chroot "$ROOTFS_DIR" systemctl enable systemd-networkd ssh >/dev/null || true

echo "[3/5] cleaning apt caches"
sudo chroot "$ROOTFS_DIR" apt-get clean
sudo rm -rf "$ROOTFS_DIR/var/lib/apt/lists/"*

echo "[4/5] packing rootfs tarball"
rm -f "$ROOTFS_TAR"
sudo tar \
    --xattrs \
    --acls \
    --numeric-owner \
    -C "$ROOTFS_DIR" \
    -cJf "$ROOTFS_TAR" \
    .
sudo chown "$(id -u):$(id -g)" "$ROOTFS_TAR"

echo "[5/5] done"
echo "rootfs tarball: $ROOTFS_TAR"
