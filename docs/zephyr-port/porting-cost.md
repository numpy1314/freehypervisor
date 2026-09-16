# Zephyr porting cost

The canonical machine-generated figures are in `artifacts/zephyr/loc-report.txt`, produced by `scripts/zephyr/loc-report.sh`. Counts are physical lines and include comments/tests; they are not normalized SLOC.

| Category | Cost | Notes |
|---|---:|---|
| Hypervisor Core | 4 modified files, `+62/-18` (net `+44`) | Three host-neutral patches; no new contract operation and no Zephyr API in Core. |
| Zephyr adapter | 1,316 lines at the recorded revision | C substrate, public C ABI header, and Rust `axvisor_api` bridge. |
| Zephyr kernel | 0 modified files / 0 lines | External module/application only. |
| Build, Guest and validation integration | 1,616 lines at the recorded revision | Kconfig/CMake, app/baseline, tiny Guests and scripts. |
| QEMU | one 15-line external patch | TCG-only real-mode NPT workaround; excluded from Core/Zephyr cost. |

## Where complexity landed

| Area | Relative glue | Reason |
|---|---|---|
| Console/topology/time query | Low | Direct Zephyr primitive mapping. |
| Execution context | Medium | Opaque handles, dynamic stacks, affinity-before-start, completion and resource join. |
| Blocking/wakeup | High | Correctness requires condition/install/recheck, generation tracking, stale-credit rejection and close/drain. |
| Physical memory | High | The Core needs explicit physical ownership, contiguity, alignment, PA↔VA access and safe handoff, not ordinary heap memory. |
| Per-CPU integration | Medium/high | Core `ax-percpu` uses an external base while Zephyr owns CPU-local execution; enable/disable must run on the target CPU. |
| IRQ/IPI | High and architecture-specific | Dedicated vector selection and local-APIC targeting currently use Zephyr x86 internal symbols. |
| Rust/static-link integration | Medium | Pinned nightly target, generated Core tree, embedded configs/Guest images and linker section for per-CPU data. |

The meaningful research cost is not an interface count alone: most methods are thin mappings, while memory ownership, blocking semantics and per-CPU notification account for most of the semantic work.

## Recompute

```sh
./scripts/zephyr/loc-report.sh
cat artifacts/zephyr/loc-report.txt
```

The report deliberately lists Core and QEMU patches separately so an emulator workaround cannot inflate or hide the OS-port cost.
