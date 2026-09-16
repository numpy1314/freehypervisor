#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

destination="$FH_BUILD_ROOT/core-src"
patch_dir="$FH_REPO_ROOT/ports/zephyr/patches"
prepared="$(mktemp -d "$FH_BUILD_ROOT/core-src.prepare.XXXXXX")"
stale_root="$(mktemp -d "$FH_BUILD_ROOT/core-src.stale.XXXXXX")"
stale="$stale_root/core-src"

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
    "$FH_REPO_ROOT"/build/zephyr/core-src.prepare.*) ;;
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
if [[ -d "$destination" ]]; then
    mv "$destination" "$stale"
fi
mv "$prepared" "$destination"
if ! rm -rf "$stale_root"; then
    echo "warning: stale generated Core tree remains at $stale_root" >&2
fi
printf '%s\n' "$actual_commit" > "$FH_BUILD_ROOT/core-source-commit.txt"
echo "prepared Core $actual_commit"
