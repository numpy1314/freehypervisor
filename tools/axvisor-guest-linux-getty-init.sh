#!/bin/sh
set -eu

BB=/bin/busybox
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

bb() {
    "$BB" "$@"
}

log() {
    printf 'axvisor-getty-init:%s\n' "$1" >/dev/console 2>/dev/null || true
    if [ -e /dev/kmsg ]; then
        printf '<6>axvisor-getty-init:%s\n' "$1" >/dev/kmsg 2>/dev/null || true
    fi
}

bb mkdir -p /proc /sys /dev /dev/pts /run /tmp /etc/init.d
bb mount -t proc proc /proc >/dev/null 2>&1 || true
bb mount -t sysfs sysfs /sys >/dev/null 2>&1 || true
bb mount -t devtmpfs devtmpfs /dev >/dev/null 2>&1 || true
bb mount -t devpts devpts /dev/pts >/dev/null 2>&1 || true

TTY_NAME=ttyS0
TTY_DEV=/dev/$TTY_NAME
if [ ! -c "$TTY_DEV" ]; then
    TTY_NAME=console
    TTY_DEV=/dev/console
fi

log "ready tty=$TTY_NAME"

exec "$BB" cttyhack /bin/sh -i <"$TTY_DEV" >"$TTY_DEV" 2>&1
