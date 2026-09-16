#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

guest_out="$FH_BUILD_ROOT/guests"
mkdir -p "$guest_out"

build_guest() {
    local source="$1"
    local output="$2"
    local object="$guest_out/${output%.bin}.o"
    as --32 "$FH_REPO_ROOT/ports/zephyr/guests/$source" -o "$object"
    ld -m elf_i386 -Ttext 0 --oformat binary -e _start "$object" -o "$guest_out/$output"
}

build_guest minimal.S minimal.bin
build_guest kick.S kick.bin
cp "$FH_REPO_ROOT/ports/zephyr/guests/vm-tcg.toml" "$guest_out/vm-tcg.toml"
cp "$FH_REPO_ROOT/ports/zephyr/guests/vm-kick-tcg.toml" "$guest_out/vm-kick-tcg.toml"
cp "$FH_REPO_ROOT/ports/zephyr/guests/vm-native.toml" "$guest_out/vm-native.toml"

for id in 1 2 3 4; do
    if (( id % 2 == 1 )); then physical_cpu=0; else physical_cpu=1; fi
    sed -e "s/id = 1/id = $id/" \
        -e "s/name = \"zephyr-minimal-tcg\"/name = \"zephyr-tcg-$id\"/" \
        -e "s/phys_cpu_sets = \[1\]/phys_cpu_sets = [$physical_cpu]/" \
        "$FH_REPO_ROOT/ports/zephyr/guests/vm-tcg.toml" > "$guest_out/vm-smp-$id.toml"
done

wc -c "$guest_out/minimal.bin" "$guest_out/kick.bin"
