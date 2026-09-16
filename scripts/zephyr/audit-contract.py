#!/usr/bin/env python3
"""Enumerate the host contract selected by the Zephyr x86_64 build.

The inventory is parsed from the pinned axvisor_api trait definitions.  Only
methods enabled for target_arch=x86_64 and no axvisor_api features are emitted.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


TRAITS = (
    ("host", "HostIf"),
    ("console", "ConsoleIf"),
    ("memory", "MemoryIf"),
    ("task", "TaskIf"),
    ("sync", "SyncIf"),
    ("time", "TimeIf"),
    ("irq", "IrqIf"),
    ("arch", "ArchIf"),
)


def trait_body(source: str, trait: str) -> tuple[str, int]:
    match = re.search(rf"pub\s+trait\s+{re.escape(trait)}\s*\{{", source)
    if match is None:
        raise ValueError(f"trait {trait} not found")
    depth = 1
    cursor = match.end()
    while cursor < len(source) and depth:
        if source[cursor] == "{":
            depth += 1
        elif source[cursor] == "}":
            depth -= 1
        cursor += 1
    if depth:
        raise ValueError(f"unterminated trait {trait}")
    return source[match.end() : cursor - 1], source.count("\n", 0, match.end()) + 1


def enabled(cfg: str) -> bool:
    if not cfg:
        return True
    if 'feature = "shell"' in cfg:
        return False
    arches = re.findall(r'target_arch\s*=\s*"([^"]+)"', cfg)
    return not arches or "x86_64" in arches


def methods(body: str, first_line: int) -> list[tuple[str, int]]:
    found: list[tuple[str, int]] = []
    previous = 0
    for match in re.finditer(r"(?m)^\s*fn\s+([A-Za-z0-9_]+)\s*\(", body):
        prefix = body[previous : match.start()]
        cfgs = re.findall(r"#\[cfg\((.*?)\)\]", prefix, flags=re.S)
        cfg = cfgs[-1] if cfgs else ""
        if enabled(cfg):
            line = first_line + body.count("\n", 0, match.start())
            found.append((match.group(1), line))
        previous = match.end()
    return found


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("core", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    api = args.core / "virtualization" / "axvisor_api" / "src"
    rows: list[str] = []
    for module, trait in TRAITS:
        path = api / f"{module}.rs"
        source = path.read_text(encoding="utf-8")
        body, first_line = trait_body(source, trait)
        for method, line in methods(body, first_line):
            rows.append(f"{module}\t{trait}::{method}\t{path.relative_to(args.core)}:{line}")
    output = "module\toperation\tdefinition\n" + "\n".join(rows) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output, encoding="utf-8")
    else:
        sys.stdout.write(output)
    print(f"contract_operation_count={len(rows)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
