#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

destination="$FH_BUILD_ROOT/core-src-audited"
patch_dir="$FH_REPO_ROOT/ports/zephyr/patches"
prepared="$(mktemp -d "$FH_BUILD_ROOT/core-src-audited.prepare.XXXXXX")"

if [[ ! -d "$FH_CORE_SOURCE/.git" ]]; then
    echo "Core source not found at $FH_CORE_SOURCE" >&2
    exit 1
fi

actual_commit="$(git -C "$FH_CORE_SOURCE" rev-parse HEAD)"
if [[ "$actual_commit" != "$FH_CORE_COMMIT" ]]; then
    echo "unexpected Core commit: $actual_commit" >&2
    exit 1
fi

case "$prepared" in
    "$FH_REPO_ROOT"/build/zephyr/core-src-audited.prepare.*) ;;
    *) echo "refusing unsafe preparation path: $prepared" >&2; exit 1 ;;
esac

mkdir -p "$prepared"
git -C "$FH_CORE_SOURCE" archive "$FH_CORE_COMMIT" | tar -x -C "$prepared"
git -C "$prepared" init -q
git -C "$prepared" config user.name "FreeHypervisor build"
git -C "$prepared" config user.email "build@localhost"
git -C "$prepared" add .
git -C "$prepared" commit -q -m pristine
for patch_file in "$patch_dir"/*.patch; do
    git -C "$prepared" apply --check "$patch_file"
    git -C "$prepared" apply "$patch_file"
    echo "applied Core patch $(basename "$patch_file")"
done
expected_diff_sha="$(git -C "$prepared" diff --binary | sha256sum | awk '{print $1}')"
if [[ -d "$destination" ]]; then
    # Preserve the destination inode tree so workspace file synchronizers do
    # not resurrect files from an older generated Core after an atomic swap.
    rsync -a --delete "$prepared/" "$destination/"
    rm -rf "$prepared"
else
    mv "$prepared" "$destination"
fi
actual_diff_sha="$(git -C "$destination" diff --binary | sha256sum | awk '{print $1}')"
if [[ "$actual_diff_sha" != "$expected_diff_sha" ]]; then
    echo "generated Core differs from the audited patch set" >&2
    exit 1
fi
printf '%s\n' "$actual_commit" > "$FH_BUILD_ROOT/core-source-commit.txt"
echo "prepared Core $actual_commit"
