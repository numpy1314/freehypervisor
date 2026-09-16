#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

set +e
"$FH_REPO_ROOT/scripts/zephyr/run-svm.sh"
status=$?
set -e

case "$status" in
    0) echo "native hardware virtualization PASS" ;;
    2) echo "native hardware virtualization BLOCKED"; exit 2 ;;
    *) exit "$status" ;;
esac
