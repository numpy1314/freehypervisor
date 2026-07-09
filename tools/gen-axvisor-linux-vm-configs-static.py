#!/usr/bin/env python3
"""Generate AxVisor static VM configs for the Linux Kbuild path.

Cargo runs axvisor_core/build.rs for the Asterinas host and emits a generated
vm_configs.rs under OUT_DIR. The Linux adapter is built by Kbuild, so it needs a
fixed-path source file that provides the same static config/image contract.
"""

from __future__ import annotations

import argparse
import gzip
import pathlib
import re
import sys


DEFAULT_DTB_IN_INITRAMFS = "guest/linux-riscv64-qemu-smp1.dtb"


def rust_raw_string(value: str) -> str:
    for hashes in range(16):
        marks = "#" * hashes
        if f'"{marks}' not in value:
            return f'r{marks}"{value}"{marks}'
    raise ValueError("unable to encode Rust raw string literal")


def replace_or_insert_kernel_key(text: str, key: str, value: str, after_key: str | None = None) -> str:
    line = f'{key} = "{value}"'
    pattern = rf'(?m)^{re.escape(key)} = ".*"$'
    text, count = re.subn(pattern, line, text, count=1)
    if count:
        return text

    if after_key is not None:
        after_pattern = rf'(?m)^({re.escape(after_key)} = .*)$'
        text, count = re.subn(after_pattern, rf'\1\n{line}', text, count=1)
        if count:
            return text

    kernel_section = re.search(r"(?m)^\[kernel\]\s*$", text)
    if not kernel_section:
        raise SystemExit("VM config does not contain a [kernel] section")
    insert_at = kernel_section.end()
    return text[:insert_at] + "\n" + line + text[insert_at:]


def align4(value: int) -> int:
    return (value + 3) & ~3


def extract_newc_member(data: bytes, member: str) -> bytes | None:
    offset = 0
    while offset + 110 <= len(data):
        header = data[offset : offset + 110]
        magic = header[:6]
        if magic not in (b"070701", b"070702"):
            raise SystemExit(f"unsupported initramfs cpio header magic at offset {offset}: {magic!r}")

        fields = [int(header[pos : pos + 8], 16) for pos in range(6, 110, 8)]
        file_size = fields[6]
        name_size = fields[11]
        name_start = offset + 110
        name_end = name_start + name_size
        if name_end > len(data):
            raise SystemExit("truncated initramfs cpio entry name")

        raw_name = data[name_start:name_end]
        name = raw_name[:-1].decode("utf-8", errors="replace")
        data_start = align4(name_end)
        data_end = data_start + file_size
        if data_end > len(data):
            raise SystemExit(f"truncated initramfs cpio entry data for {name}")

        if name == "TRAILER!!!":
            return None
        if name == member:
            return data[data_start:data_end]

        offset = align4(data_end)
    return None


def extract_dtb_from_initramfs(initramfs: pathlib.Path, generated_dir: pathlib.Path) -> pathlib.Path:
    generated_dir.mkdir(parents=True, exist_ok=True)
    out = generated_dir / pathlib.Path(DEFAULT_DTB_IN_INITRAMFS).name
    data = gzip.decompress(initramfs.read_bytes())
    dtb = extract_newc_member(data, DEFAULT_DTB_IN_INITRAMFS)
    if dtb is None:
        raise SystemExit(f"{DEFAULT_DTB_IN_INITRAMFS} not found in initramfs: {initramfs}")
    out.write_bytes(dtb)
    return out


def resolve_existing(path_text: str, base_dir: pathlib.Path) -> pathlib.Path | None:
    if not path_text:
        return None
    path = pathlib.Path(path_text)
    candidates = [path] if path.is_absolute() else [pathlib.Path.cwd() / path, base_dir / path]
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    return None


def build_static_config(args: argparse.Namespace) -> tuple[str, int, pathlib.Path, pathlib.Path | None, pathlib.Path | None, pathlib.Path | None]:
    config_path = args.config.resolve()
    config_dir = config_path.parent
    text = config_path.read_text()
    wants_dtb = re.search(r"(?m)^\s*dtb_(path|load_addr)\s*=", text) is not None

    kernel = resolve_existing(str(args.kernel), config_dir)
    if kernel is None:
        raise SystemExit(f"guest kernel image not found: {args.kernel}")

    dtb = resolve_existing(str(args.dtb), config_dir) if args.dtb else None
    if dtb is None and args.initramfs and wants_dtb:
        initramfs_for_dtb = resolve_existing(str(args.initramfs), config_dir)
        if initramfs_for_dtb is not None:
            dtb = extract_dtb_from_initramfs(initramfs_for_dtb, args.generated_dir.resolve())

    initramfs = None
    if args.embed_initramfs:
        if not args.initramfs:
            raise SystemExit("--embed-initramfs requires --initramfs")
        initramfs = resolve_existing(str(args.initramfs), config_dir)
        if initramfs is None:
            raise SystemExit(f"guest initramfs image not found: {args.initramfs}")

    text = replace_or_insert_kernel_key(text, "image_location", "memory")
    text = replace_or_insert_kernel_key(text, "kernel_path", str(kernel))
    if dtb is not None:
        text = replace_or_insert_kernel_key(text, "dtb_path", str(dtb), after_key="kernel_load_addr")
    if initramfs is not None:
        text = replace_or_insert_kernel_key(text, "ramdisk_path", str(initramfs), after_key="dtb_load_addr")

    base_match = re.search(r"(?ms)^\[base\]\s*(.*?)(?:^\[|\Z)", text)
    if not base_match:
        raise SystemExit("VM config does not contain a [base] section")
    id_match = re.search(r"(?m)^id\s*=\s*(\d+)\s*$", base_match.group(1))
    if not id_match:
        raise SystemExit("VM config [base] section does not contain an integer id")
    vm_id = int(id_match.group(1))

    kernel_match = re.search(r"(?ms)^\[kernel\]\s*(.*?)(?:^\[|\Z)", text)
    if not kernel_match:
        raise SystemExit("VM config does not contain a [kernel] section")
    image_match = re.search(r'(?m)^image_location\s*=\s*"([^"]+)"\s*$', kernel_match.group(1))
    if not image_match or image_match.group(1) != "memory":
        got = image_match.group(1) if image_match else None
        raise SystemExit(f'generated VM config must use image_location = "memory", got {got!r}')

    return text, vm_id, kernel, dtb, None, initramfs


def image_expr(path: pathlib.Path | None) -> str:
    if path is None:
        return "None"
    return f"Some(include_bytes!({rust_raw_string(str(path))}))"


def generate_rs(static_config: str, vm_id: int, kernel: pathlib.Path, dtb: pathlib.Path | None, bios: pathlib.Path | None, ramdisk: pathlib.Path | None) -> str:
    config_literal = rust_raw_string(static_config)
    kernel_literal = rust_raw_string(str(kernel))
    return f"""/// Static VM config strings embedded by Linux Kbuild.
pub fn static_vm_configs() -> Vec<&'static str> {{
    vec![{config_literal}]
}}

/// One guest image data from memory.
pub struct MemoryImage {{
    /// VM id in config file.
    pub id: usize,
    /// Kernel image bytes.
    pub kernel: &'static [u8],
    /// Optional DTB image bytes.
    pub dtb: Option<&'static [u8]>,
    /// Optional BIOS image bytes.
    pub bios: Option<&'static [u8]>,
    /// Optional ramdisk image bytes.
    pub ramdisk: Option<&'static [u8]>,
}}

/// Guest images embedded by Linux Kbuild.
pub fn get_memory_images() -> &'static [MemoryImage] {{
    &[MemoryImage {{
        id: {vm_id},
        kernel: include_bytes!({kernel_literal}),
        dtb: {image_expr(dtb)},
        bios: {image_expr(bios)},
        ramdisk: {image_expr(ramdisk)},
    }}]
}}
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, type=pathlib.Path)
    parser.add_argument("--kernel", required=True, type=pathlib.Path)
    parser.add_argument("--dtb", type=pathlib.Path)
    parser.add_argument("--initramfs", type=pathlib.Path)
    parser.add_argument("--generated-dir", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--embed-initramfs", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    static_config, vm_id, kernel, dtb, bios, ramdisk = build_static_config(args)
    output = generate_rs(static_config, vm_id, kernel, dtb, bios, ramdisk)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists() and args.output.read_text() == output:
        print(f"unchanged {args.output}")
    else:
        args.output.write_text(output)
        print(f"generated {args.output}")
    print(f"embedded vm_id={vm_id} kernel={kernel}")
    if dtb is not None:
        print(f"embedded dtb={dtb}")
    if ramdisk is not None:
        print(f"embedded ramdisk={ramdisk}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
