#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

zephyr_commit="684c9e8f32e4373a21098559f748f06915f950c9"

checkout_pinned_repo() {
    local url="$1"
    local directory="$2"
    local commit="$3"

    if [[ ! -d "$directory/.git" ]]; then
        git clone --filter=blob:none --no-checkout "$url" "$directory"
        git -C "$directory" fetch --depth 1 origin "$commit"
        git -C "$directory" checkout --detach "$commit"
    fi
    local actual
    actual="$(git -C "$directory" rev-parse HEAD)"
    if [[ "$actual" != "$commit" ]]; then
        echo "unexpected commit in $directory: $actual (wanted $commit)" >&2
        exit 1
    fi
}

checkout_pinned_repo https://github.com/zephyrproject-rtos/zephyr.git \
    "$FH_ZEPHYR_BASE" "$zephyr_commit"
checkout_pinned_repo https://github.com/rcore-os/tgoskits.git \
    "$FH_CORE_SOURCE" "$FH_CORE_COMMIT"
git -C "$FH_REPO_ROOT" submodule update --init --recursive linux-host-kernel

if [[ ! -x "$FH_WEST" ]]; then
    python3 -m venv "$FH_VENV"
    "$FH_VENV/bin/python" -m pip install west -r "$FH_ZEPHYR_BASE/scripts/requirements.txt"
fi

rustup toolchain install nightly-2026-05-28 --profile minimal --component rust-src
rustup target add --toolchain nightly-2026-05-28 x86_64-unknown-none

"$FH_WEST" --version
cmake --version | head -1
ninja --version
"$FH_QEMU" --version | head -1
rustc +nightly-2026-05-28 --version
