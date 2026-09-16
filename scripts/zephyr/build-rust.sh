#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

profile="${1:-single}"
"$FH_REPO_ROOT/scripts/zephyr/prepare-core.sh"
"$FH_REPO_ROOT/scripts/zephyr/build-guests.sh"

case "$profile" in
    single)
        configs="$FH_BUILD_ROOT/guests/vm-tcg.toml"
        ;;
    kick)
        configs="$FH_BUILD_ROOT/guests/vm-kick-tcg.toml"
        ;;
    smp)
        configs="$FH_BUILD_ROOT/guests/vm-smp-1.toml:$FH_BUILD_ROOT/guests/vm-smp-2.toml:$FH_BUILD_ROOT/guests/vm-smp-3.toml:$FH_BUILD_ROOT/guests/vm-smp-4.toml"
        ;;
    native)
        configs="$FH_BUILD_ROOT/guests/vm-native.toml"
        ;;
    *)
        echo "unknown Rust profile: $profile" >&2
        exit 1
        ;;
esac

export AXVISOR_VM_CONFIGS="$configs"
export FH_GUEST_MINIMAL_BIN="$FH_BUILD_ROOT/guests/minimal.bin"
export FH_GUEST_KICK_BIN="$FH_BUILD_ROOT/guests/kick.bin"
export CARGO_TARGET_DIR="$FH_BUILD_ROOT/rust-$profile"

cargo +nightly-2026-05-28 build \
    --manifest-path "$FH_REPO_ROOT/ports/zephyr/rust/Cargo.toml" \
    --target x86_64-unknown-none \
    --release

rust_lib="$CARGO_TARGET_DIR/x86_64-unknown-none/release/libfreehypervisor_zephyr.a"
fh_require_file "$rust_lib"
printf '%s\n' "$rust_lib"
