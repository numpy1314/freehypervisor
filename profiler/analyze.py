#!/usr/bin/env python3
"""
analyze.py — HHAL Host Service Dependency Profiler: Analysis Engine

Parses strace output from runner.sh, maps raw events to architecture-agnostic
service abstractions via mapping.yaml, and generates reports.

Usage:
    python3 analyze.py [output_dir]
"""

import csv
import json
import os
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

import yaml

# Add profiler dir to path for kvm_ioctl_map
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
from kvm_ioctl_map import KVM_IOCTL_MAP

# Reverse map for ioctl name lookup from hex numbers
_IOCTL_NUM_TO_NAME = {k: v for k, v in KVM_IOCTL_MAP.items()}

# VM lifecycle phases in order
PHASES = ["VM_CREATE", "VM_BOOT", "STEADY_IDLE", "STEADY_IO", "VM_DESTROY"]

# === strace line parser ===
# Format: PID  TIMESTAMP SYSCALL(args...) = RESULT <LATENCY>
# Examples:
#   1234  1716000000.123456 mmap(NULL, 4096, ...) = 0x7f... <0.000123>
#   1234  1716000000.123456 ioctl(17, KVM_RUN, 0) = 0 <0.001234>
#   1234  1716000000.123456 ioctl(17, 0xae46, 0x7ff...) = 0 <0.000100>
#   1234  1716000000.456789 +++ exited with 0 +++

# strace -ff -o outputs per-thread files: each line is:
#   HH:MM:SS.ffffff syscall(args) = result <latency>
# PID is embedded in the filename (qemu.PID), not in each line.
# Some lines may also have PID prefix if strace config differs.
_RE_SYSCALL_WITH_PID = re.compile(
    r'^\s*(\d+)\s+'              # PID (optional)
    r'(\d+\.\d+)\s+'             # timestamp (epoch)
    r'(\w+)\('                   # syscall name
)
_RE_SYSCALL_NO_PID = re.compile(
    r'^\s*'                      # no PID
    r'(\d+:\d+:\d+\.\d+)\s+'     # timestamp (HH:MM:SS.ffffff)
    r'(\w+)\('                   # syscall name
)

# Match ioctl lines specifically to extract the request code
_RE_IOCTL_ARG = re.compile(
    r'ioctl\(\d+,\s*([^,\s)]+)'
)

# Match hex ioctl number
_RE_IOCTL_HEX = re.compile(r'^0x[0-9a-fA-F]+$')

# Match latency at end of line
_RE_LATENCY = re.compile(r'<(\d+\.\d+)>$')

# Match unfinished/resumed lines (strace -ff artifacts)
_RE_UNFINISHED = re.compile(r'<unfinished\s*\.\.\.>$')
_RE_RESUMED = re.compile(r'^\s*(\d+\s+)?\d+[:\d]*\s+\+\+\+')

# Match signal/exit lines
_RE_SIGNAL = re.compile(r'^\s*(\d+\s+)?\d+[:\d]*\s+(\+\+\+|---)')


def _parse_wallclock_ts(ts_str: str) -> float:
    """Convert HH:MM:SS.ffffff to epoch-like float for sorting/comparison.

    Since we only need relative ordering within a single run, we convert
    to total seconds. The absolute value doesn't matter as long as it's
    consistent — phase boundaries use the same wall-clock format via `date +%s.%N`.
    """
    # We need a real epoch for phase matching. Since runner.sh uses `date +%s.%N`
    # for phase timestamps, we need to convert strace's HH:MM:SS to epoch too.
    # For simplicity, parse the HH:MM:SS and combine with the epoch from phases.
    # Actually, we'll just use the seconds-since-midnight as a relative timestamp.
    # Phase timestamps from runner.sh are epoch seconds, but the strace output is
    # wall-clock. We handle this in parse_strace_files by computing an offset.
    parts = ts_str.split(":")
    h, m, s = int(parts[0]), int(parts[1]), float(parts[2])
    return h * 3600 + m * 60 + s


def parse_strace_line(line: str, default_pid: int = 0) -> dict | None:
    """Parse a single strace output line into an event dict.

    Returns None for non-syscall lines (signals, unfinished, etc.).
    default_pid: PID extracted from filename when using -ff -o mode.
    """
    line = line.strip()
    if not line:
        return None

    # Skip signal/exit/unfinished lines
    if _RE_UNFINISHED.search(line) or _RE_RESUMED.match(line):
        return None
    if _RE_SIGNAL.match(line):
        return None

    # Try format with PID prefix (epoch timestamp)
    m = _RE_SYSCALL_WITH_PID.match(line)
    if m:
        pid = int(m.group(1))
        timestamp = float(m.group(2))
        syscall_name = m.group(3)
    else:
        # Try format without PID (HH:MM:SS timestamp from -ff -o mode)
        m = _RE_SYSCALL_NO_PID.match(line)
        if not m:
            return None
        pid = default_pid
        timestamp = _parse_wallclock_ts(m.group(1))
        syscall_name = m.group(2)

    # Extract latency
    latency_ns = 0
    lat_m = _RE_LATENCY.search(line)
    if lat_m:
        latency_ns = int(float(lat_m.group(1)) * 1e9)

    # Determine source and raw_name
    source = "syscall"
    raw_name = syscall_name

    if syscall_name == "ioctl":
        # Try to extract ioctl request arg
        ioctl_m = _RE_IOCTL_ARG.search(line)
        if ioctl_m:
            ioctl_arg = ioctl_m.group(1).strip()
            if _RE_IOCTL_HEX.match(ioctl_arg):
                # Raw hex number → decode via KVM_IOCTL_MAP
                try:
                    ioctl_num = int(ioctl_arg, 16)
                    decoded = _IOCTL_NUM_TO_NAME.get(ioctl_num)
                    if decoded:
                        raw_name = decoded
                    else:
                        raw_name = f"ioctl_0x{ioctl_num:x}"
                except ValueError:
                    raw_name = "ioctl_unknown"
            else:
                # strace already decoded it (e.g., "KVM_RUN")
                raw_name = ioctl_arg
            source = "ioctl"

    return {
        "pid": pid,
        "timestamp": timestamp,
        "source": source,
        "raw_name": raw_name,
        "latency_ns": latency_ns,
        "line": line,
    }


def parse_strace_files(strace_dir: Path, phases: list[tuple[str, float]]) -> list[dict]:
    """Parse all strace output files in the directory.

    Handles two strace timestamp formats:
    - With PID prefix: uses epoch timestamps directly
    - Without PID (HH:MM:SS): converts wall-clock to epoch by computing
      an offset from the first phase boundary.
    """
    events = []
    strace_files = sorted(strace_dir.glob("qemu.*"))

    if not strace_files:
        print(f"WARNING: No strace files found in {strace_dir}")
        return events

    # Detect format and compute wall-clock → epoch offset if needed.
    # Sample first line of first file to check format.
    with open(strace_files[0], "r", errors="replace") as f:
        first_line = f.readline().strip()

    has_pid_prefix = bool(_RE_SYSCALL_WITH_PID.match(first_line))

    if not has_pid_prefix and phases:
        # Wall-clock mode: compute offset.
        # The VM_CREATE phase timestamp (epoch) roughly corresponds to
        # the first strace event (wall-clock). We'll compute the offset
        # after parsing all events.
        wallclock_mode = True
    else:
        wallclock_mode = False

    for fpath in strace_files:
        tid = fpath.name.split(".")[-1] if "." in fpath.name else "?"
        try:
            with open(fpath, "r", errors="replace") as f:
                for line in f:
                    ev = parse_strace_line(line, default_pid=int(tid))
                    if ev:
                        ev["tid"] = tid
                        events.append(ev)
        except Exception as e:
            print(f"WARNING: Error reading {fpath}: {e}")

    if not events:
        print(f"Parsed 0 events from {len(strace_files)} strace files")
        return events

    # Sort by timestamp
    events.sort(key=lambda e: e["timestamp"])

    # Convert wall-clock timestamps to epoch if needed
    if wallclock_mode and phases:
        # Find the first event's wall-clock time and align with VM_CREATE epoch
        # Strategy: VM_CREATE epoch should be just before the first event.
        # Use the VM_CREATE phase as reference point.
        vm_create_epoch = phases[0][1]  # first phase is VM_CREATE
        first_event_wall = events[0]["timestamp"]

        # The first event happens right at or slightly after VM_CREATE.
        # Offset = VM_CREATE_epoch - first_event_wall
        offset = vm_create_epoch - first_event_wall

        for ev in events:
            ev["timestamp"] += offset

    print(f"Parsed {len(events)} events from {len(strace_files)} strace files")
    return events


def load_mapping(mapping_path: Path) -> dict:
    """Load mapping.yaml and return a lookup dict keyed by (source, raw_name)."""
    with open(mapping_path) as f:
        rules = yaml.safe_load(f)

    lookup = {}
    for rule in rules:
        key = (rule["source"], rule["raw_name"])
        lookup[key] = {
            "service_class": rule["service_class"],
            "service_name": rule["service_name"],
            "direction": rule["direction"],
        }
    return lookup


def load_phases(phases_path: Path) -> list[tuple[str, float]]:
    """Load phases.tsv and return sorted list of (phase_name, timestamp)."""
    phases = []
    with open(phases_path) as f:
        reader = csv.reader(f, delimiter="\t")
        next(reader)  # skip header
        for row in reader:
            if len(row) >= 2:
                phases.append((row[0], float(row[1])))
    phases.sort(key=lambda x: x[1])
    return phases


def classify_phase(timestamp: float, phases: list[tuple[str, float]]) -> str:
    """Determine which VM lifecycle phase a timestamp falls into."""
    # Find the last phase whose timestamp <= event timestamp
    current_phase = "UNKNOWN"
    for phase_name, phase_ts in phases:
        if timestamp >= phase_ts:
            current_phase = phase_name
        else:
            break
    return current_phase


def normalize_events(
    events: list[dict],
    mapping: dict,
    phases: list[tuple[str, float]],
) -> list[dict]:
    """Map raw events to semantic HHAL service events."""
    normalized = []
    unmapped_counter = Counter()

    for ev in events:
        key = (ev["source"], ev["raw_name"])
        mapped = mapping.get(key)

        if mapped is None:
            unmapped_counter[key] += 1
            continue

        phase = classify_phase(ev["timestamp"], phases)

        normalized.append({
            "timestamp": ev["timestamp"],
            "pid": ev["pid"],
            "tid": ev.get("tid", "?"),
            "source": ev["source"],
            "raw_name": ev["raw_name"],
            "service_class": mapped["service_class"],
            "service_name": mapped["service_name"],
            "direction": mapped["direction"],
            "phase": phase,
        })

    if unmapped_counter:
        print(f"\nUnmapped events (not in mapping.yaml):")
        for (src, name), count in unmapped_counter.most_common(20):
            print(f"  {src}:{name} → {count} occurrences")
        print(f"  (Total unmapped: {sum(unmapped_counter.values())} / {len(events)})")

    return normalized


def generate_reports(
    events: list[dict],
    outdir: Path,
):
    """Generate host_service_matrix.csv and phase_service_report.md."""

    # Count events by (service_class, service_name, phase)
    counts: dict[tuple[str, str, str], int] = Counter()
    evidence: dict[tuple[str, str], set] = defaultdict(set)

    for ev in events:
        key = (ev["service_class"], ev["service_name"], ev["phase"])
        counts[key] += 1
        evidence[(ev["service_class"], ev["service_name"])].add(ev["raw_name"])

    # === CSV: Service × Phase matrix ===
    csv_path = outdir / "host_service_matrix.csv"

    # Collect all unique (service_class, service_name) pairs
    services = sorted(
        {(ev["service_class"], ev["service_name"]) for ev in events},
        key=lambda x: (x[0], x[1]),
    )

    with open(csv_path, "w", newline="") as f:
        writer = csv.writer(f)
        header = ["service_class", "service_name"] + PHASES + ["total"]
        writer.writerow(header)

        for sc, sn in services:
            row = [sc, sn]
            total = 0
            for phase in PHASES:
                c = counts.get((sc, sn, phase), 0)
                row.append(c)
                total += c
            row.append(total)
            writer.writerow(row)

    print(f"\nWrote {csv_path}")

    # === Markdown report ===
    md_path = outdir / "phase_service_report.md"

    with open(md_path, "w") as f:
        f.write("# HHAL Host Service Dependency Report\n\n")
        f.write(f"Total mapped events: {len(events)}\n\n")

        # Summary table
        f.write("## Summary\n\n")
        f.write("| Service Class | Count | Unique Services |\n")
        f.write("|---|---:|---:|\n")
        class_counts: dict[str, int] = Counter()
        class_services: dict[str, set] = defaultdict(set)
        for ev in events:
            class_counts[ev["service_class"]] += 1
            class_services[ev["service_class"]].add(ev["service_name"])
        for sc in sorted(class_counts.keys()):
            f.write(
                f"| {sc} | {class_counts[sc]} | {len(class_services[sc])} |\n"
            )
        f.write("\n")

        # Phase breakdown
        f.write("## Phase Breakdown\n\n")
        phase_counts: dict[str, int] = Counter()
        for ev in events:
            phase_counts[ev["phase"]] += 1
        f.write("| Phase | Events |\n")
        f.write("|---|---:|\n")
        for phase in PHASES:
            f.write(f"| {phase} | {phase_counts.get(phase, 0)} |\n")
        f.write("\n")

        # Per-service-class details
        for sc in sorted(class_services.keys()):
            f.write(f"## {sc} Services\n\n")
            f.write("| Service | Evidence | Total")
            for phase in PHASES:
                f.write(f" | {phase}")
            f.write(" |\n")
            f.write("|---|---|---:")
            for _ in PHASES:
                f.write(" | ---:")
            f.write(" |\n")

            for sn in sorted(class_services[sc]):
                ev_list = sorted(evidence.get((sc, sn), set()))
                ev_str = ", ".join(ev_list)
                total = sum(counts.get((sc, sn, p), 0) for p in PHASES)
                f.write(f"| {sn} | {ev_str} | {total}")
                for phase in PHASES:
                    f.write(f" | {counts.get((sc, sn, phase), 0)}")
                f.write(" |\n")
            f.write("\n")

    print(f"Wrote {md_path}")


def write_raw_events(events: list[dict], outpath: Path):
    """Write normalized events as JSONL."""
    with open(outpath, "w") as f:
        for ev in events:
            f.write(json.dumps(ev) + "\n")
    print(f"Wrote {outpath} ({len(events)} events)")


def main():
    outdir = Path(sys.argv[1]) if len(sys.argv) > 1 else SCRIPT_DIR.parent / "data"

    strace_dir = outdir / "strace"
    mapping_path = SCRIPT_DIR / "mapping.yaml"
    phases_path = outdir / "phases.tsv"

    print("=== HHAL Profiler: analyze.py ===")
    print(f"Data dir:   {outdir}")
    print(f"Strace dir: {strace_dir}")
    print(f"Mapping:    {mapping_path}")
    print(f"Phases:     {phases_path}")
    print()

    # Validate inputs
    if not strace_dir.exists():
        print(f"ERROR: {strace_dir} not found. Run runner.sh first.")
        sys.exit(1)
    if not mapping_path.exists():
        print(f"ERROR: {mapping_path} not found.")
        sys.exit(1)
    if not phases_path.exists():
        print(f"ERROR: {phases_path} not found. Run runner.sh first.")
        sys.exit(1)

    # 1. Load mapping
    mapping = load_mapping(mapping_path)
    print(f"Loaded {len(mapping)} mapping rules")

    # 2. Load phases (needed for wall-clock→epoch conversion)
    phases = load_phases(phases_path)
    print(f"Loaded {len(phases)} phase boundaries")

    # 3. Parse strace
    raw_events = parse_strace_files(strace_dir, phases)

    # 4. Normalize (map + phase-classify)
    normalized = normalize_events(raw_events, mapping, phases)
    print(f"Normalized: {len(normalized)} / {len(raw_events)} events mapped")

    # 5. Write raw events
    write_raw_events(normalized, outdir / "raw_events.jsonl")

    # 6. Generate reports
    generate_reports(normalized, outdir)

    print("\n=== Analysis complete ===")


if __name__ == "__main__":
    main()
