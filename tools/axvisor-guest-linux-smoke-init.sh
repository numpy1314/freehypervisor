#!/bin/sh

BB=/bin/busybox
RESULT=/axvisor-smoke-result.txt
LOG=/axvisor-smoke.log

bb() {
    "$BB" "$@"
}

kmsg() {
    if [ -e /dev/kmsg ]; then
        printf '<6>axvisor-smoke:%s\n' "$1" > /dev/kmsg 2>/dev/null || true
    fi
}

bb mount -t proc proc /proc >/dev/null 2>&1 || true
bb mount -t sysfs sysfs /sys >/dev/null 2>&1 || true
bb mount -t devtmpfs devtmpfs /dev >/dev/null 2>&1 || true

kmsg "stage=before-log-redirect"
exec >"$LOG" 2>&1
kmsg "stage=after-log-redirect"

echo "AXVISOR_SMOKE_STAGE=boot"
kmsg "stage=boot"

CMDLINE="$(bb cat /proc/cmdline 2>/dev/null)"
CMDLINE="${CMDLINE:-unknown}"
UNAME_LINE="$(bb uname -a 2>/dev/null)"
UNAME_LINE="${UNAME_LINE:-unknown}"
DATE_LINE="$(bb date -Iseconds 2>/dev/null)"
if [ -z "$DATE_LINE" ]; then
    DATE_LINE="$(bb date 2>/dev/null)"
fi
DATE_LINE="${DATE_LINE:-unknown}"

ROOT_MOUNT_DEV=""
ROOT_MOUNT_FS=""
kmsg "stage=before-mounts-parse"
if [ -r /proc/mounts ]; then
    ROOT_MOUNT_LINE="$(bb awk '$2 == "/" { print $1 " " $3; exit }' /proc/mounts 2>/dev/null)"
    ROOT_MOUNT_DEV="${ROOT_MOUNT_LINE%% *}"
    ROOT_MOUNT_FS="${ROOT_MOUNT_LINE#* }"
    if [ "$ROOT_MOUNT_DEV" = "$ROOT_MOUNT_LINE" ]; then
        ROOT_MOUNT_FS=""
    fi
fi
kmsg "stage=after-mounts-parse"

kmsg "stage=before-write-test"
if echo "axvisor smoke write test" > /axvisor-smoke-write-test.txt; then
    SMOKE_WRITE_TEST=1
else
    SMOKE_WRITE_TEST=0
fi
kmsg "stage=after-write-test"
kmsg "stage=before-sync-write-test"
bb sync >/dev/null 2>&1 || true
kmsg "stage=after-sync-write-test"

kmsg "stage=before-result"
if {
    echo "AXVISOR_SMOKE_PASS=1"
    echo "DATE=$DATE_LINE"
    echo "UNAME=$UNAME_LINE"
    echo "CMDLINE=$CMDLINE"
    if [ -b /dev/vda ]; then
        echo "HAS_DEV_VDA=1"
    else
        echo "HAS_DEV_VDA=0"
    fi
    if [ -d /sys/block/vda ]; then
        echo "HAS_SYS_BLOCK_VDA=1"
    else
        echo "HAS_SYS_BLOCK_VDA=0"
    fi
    if [ -r /proc/mounts ]; then
        echo "HAS_PROC_MOUNTS=1"
    else
        echo "HAS_PROC_MOUNTS=0"
    fi
    echo "ROOT_MOUNT_DEV=$ROOT_MOUNT_DEV"
    echo "ROOT_MOUNT_FS=$ROOT_MOUNT_FS"
    echo "SMOKE_WRITE_TEST=$SMOKE_WRITE_TEST"
    echo "PROC_MOUNTS_BEGIN"
    bb cat /proc/mounts 2>/dev/null || true
    echo "PROC_MOUNTS_END"
} >"$RESULT"; then
    kmsg "stage=after-result"
else
    kmsg "stage=result-write-failed"
fi

kmsg "stage=before-final-sync"
bb sync >/dev/null 2>&1 || true
kmsg "stage=after-final-sync"
bb sleep 1 || true

echo "AXVISOR_SMOKE_STAGE=poweroff"
kmsg "stage=before-poweroff"
bb poweroff -f || bb halt -f || bb reboot -f || true

while :; do
    bb sleep 1 || true
done
