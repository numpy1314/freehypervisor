#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_DIR="${KERNEL_DIR:-$ROOT_DIR/linux-host-kernel}"
OUTPUT_DIR="${1:-/tmp/freehypervisor-linux-host-kernel-package}"
XZ_THREADS="${XZ_THREADS:-1}"
XZ_LEVEL="${XZ_LEVEL:-6}"

[[ -d "$KERNEL_DIR/.git" ]] || {
    echo "linux-host-kernel must be an initialized Git checkout: $KERNEL_DIR" >&2
    exit 1
}

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd -- "$OUTPUT_DIR" && pwd)"

HEAD_REVISION="$(git -C "$KERNEL_DIR" rev-parse HEAD)"
HEAD_SUBJECT="$(git -C "$KERNEL_DIR" log -1 --format=%s)"
PATCH_FILE="$OUTPUT_DIR/linux-host-kernel-local-changes.patch"
ARCHIVE_FILE="$OUTPUT_DIR/linux-host-kernel-source.tar.xz"
MANIFEST_FILE="$OUTPUT_DIR/MANIFEST.txt"

cleanup_partial_archive() {
    rm -f "$ARCHIVE_FILE"
}
trap cleanup_partial_archive ERR

git -C "$KERNEL_DIR" diff --binary HEAD >"$PATCH_FILE"
git -C "$KERNEL_DIR" archive --format=tar --prefix=linux-host-kernel/ "$HEAD_REVISION" | xz -T"$XZ_THREADS" -"$XZ_LEVEL" >"$ARCHIVE_FILE"

cat >"$MANIFEST_FILE" <<EOF
Linux host kernel handoff package

Upstream repository: $(git -C "$KERNEL_DIR" remote get-url origin)
Base revision: $HEAD_REVISION
Base subject: $HEAD_SUBJECT
Local patch: $(basename "$PATCH_FILE")
Source archive: $(basename "$ARCHIVE_FILE")

The source archive contains only files tracked by the kernel repository at the
base revision. It intentionally excludes the kernel .git directory and all
untracked build directories and generated artifacts.

To reconstruct the working tree:
  tar -xf $(basename "$ARCHIVE_FILE")
  cd linux-host-kernel
  git init
  git apply --index ../$(basename "$PATCH_FILE")

For a reviewable repository with history, publish this checkout to a dedicated
Linux fork, then apply $(basename "$PATCH_FILE") and commit it there. Do not
commit this archive or build output to the freehypervisor repository.
EOF

echo "created: $ARCHIVE_FILE"
echo "created: $PATCH_FILE"
echo "created: $MANIFEST_FILE"

trap - ERR
