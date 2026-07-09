#!/bin/sh
set -eu

RESULT=/axvisor-smoke-result.txt

printf '<6>axvisor-smoke-minimal:stage=start\n' >/dev/kmsg 2>/dev/null || true

{
    echo "AXVISOR_SMOKE_PASS=1"
    echo "MODE=minimal"
} >"$RESULT"

printf '<6>axvisor-smoke-minimal:stage=after-result\n' >/dev/kmsg 2>/dev/null || true
sync >/dev/null 2>&1 || true
printf '<6>axvisor-smoke-minimal:stage=after-sync\n' >/dev/kmsg 2>/dev/null || true

poweroff -f >/dev/null 2>&1 || halt -f >/dev/null 2>&1 || reboot -f >/dev/null 2>&1 || true

while :; do
    sleep 1 || true
done
