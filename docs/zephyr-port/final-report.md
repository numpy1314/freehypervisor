# Zephyr x86_64 port final engineering report

## Executive result

The same pinned Hypervisor Core now builds as a `no_std` static library, links into Zephyr 4.4.0 through an external host adapter, enables the Core's existing SVM backend independently on two Zephyr CPUs, and boots Linux 7.1.0-rc6 to PID 1. PID 1 executes `uname`, emits an explicit PASS marker, requests shutdown through scalar port I/O, and the Core then joins the vCPU, quiesces its virtual timer, and disables SVM on both CPUs.

The successful execution was performed by **patched QEMU 8.2.2 TCG**, so it is a software-emulated SVM result. The execution host exposes neither VMX nor SVM and has no `/dev/kvm`; native VMX/native SVM are correctly recorded as **BLOCKED**, not PASS.

The port preserves the research boundary: Zephyr supplies host authority through the existing contract; entry/exit, VMCB, NPT, vCPU loop, emulated devices and exit decoding remain in the Core. No Zephyr kernel file is modified. Five host-neutral Core fixes are required and fully accounted for.

## Revisions and configuration

| Input | Pinned value |
|---|---|
| FreeHypervisor base | `628dec483f0160cbd6035034bf3af4889f6350a4` |
| Tested local Zephyr-port implementation | `29704d17a9663f8521332a3545b64ff5862b94f7` |
| Published tree-equivalent implementation | `19444749514592616d3e0ce35f2a0ef245bbe28c` (tree `13f020559150ef6e42c686982f298bef0149af6a`) |
| Hypervisor Core | `534de06e3855a31ff2d74e9faa75c6cdcc2cf8d8` |
| Linux host submodule | `66936b14da0f71cac105a9c4b7eb8e25032f13a0` |
| Asterinas reference | `68226d2303136dc8bf851937087f4a8c61748575` |
| Zephyr | `684c9e8f32e4373a21098559f748f06915f950c9` (v4.4.0) |
| QEMU TCG source | `11aa0b1ff115b86160c4d37e7c37e6a6b13b77ea` (v8.2.2) plus recorded NPT patch |
| Rust | `nightly-2026-05-28`, target `x86_64-unknown-none` |
| Core feature selection | `default-features=false`, `svm` |

## Milestones

| Milestone | Result | Evidence / qualification |
|---|---|---|
| M0 — repository understood | PASS | Source-derived inventory: 25 formal operations for this exact revision/target/features; Linux revision gap and exact Asterinas mapping recorded. |
| M1 — Zephyr baseline | PASS | Two CPUs, MMU translation, pinned thread, semaphore, spinlock, timer and directed vector-239 IPI in `baseline.log`. |
| M2 — adapter linked | PASS | Same Core builds as staticlib; contract/lifetime apps link and pass. |
| M3 — virtualization enable/disable | SOFTWARE-EMULATED PASS; NATIVE BLOCKED | SVM probe reports SVM+NPT; distinct HSAVE pages on both pCPUs; two SVM-off events. `/dev/kvm` absent. VMX probe blocked. |
| M4 — real VM execution | SOFTWARE-EMULATED PASS; NATIVE BLOCKED | `VMRUN` boots Linux 7.1.0-rc6 through `Run /init`; PID 1 reports `uname=Linux ... x86_64` and `pid=1 result=PASS`; scalar OUT becomes `SystemDown`; teardown is clean. |
| M5 — SMP/notification | SOFTWARE-EMULATED PASS | Both Zephyr CPUs independently enable/disable SVM; Linux timer progress exercises dedicated vector-240 kicks, and Linux setup registers free host IRQ forwarding vectors. No physical passthrough IRQ is claimed. The earlier directed-window micro-Guest remains supplemental. Native timing is blocked. |
| M6 — lifetime/concurrency | PASS for implemented windows | Forced lost-wake window, stale credit, wake-all, close/drain, timer single-fire, physical ownership handoff and negative control pass; task publication and teardown regressions pass. |
| M7 — oversubscription | SUPPLEMENTAL MICRO-GUEST PASS | Existing artifacts record four one-vCPU VMs on two pCPUs for 20 runs. Linux acceptance is single-vCPU; same-VM Linux AP/SIPI and Linux oversubscription remain future work. |

## Linux Guest acceptance evidence

The reproducible Linux workload is built from the pinned `linux-host-kernel` submodule with an `allnoconfig`-derived x86_64 configuration. The Core directly boots its bzImage with 64 MiB RAM, an initramfs, emulated COM1, IOAPIC and PIT. The libc-free `/init` is real Linux userspace PID 1.

The automated run requires, in order:

1. the Linux version banner and `Run /init as init process`;
2. `FH_LINUX_GUEST userspace-entered`;
3. `FH_LINUX_GUEST uname=Linux 7.1.0-rc6+ x86_64`;
4. `FH_LINUX_GUEST pid=1 result=PASS`;
5. `VM[1] run VCpu[0] SystemDown` caused by PID 1's `OUTW 0x604, 0x2000`;
6. VM `Stopped`, joined vCPU resources, two SVM-off completions, and `FH_RESULT core-static result=PASS`;
7. absence of assertion, fatal, late-interrupt, or quiesce failure markers.

These observations require Guest kernel and userspace instructions to execute after SVM entry; they cannot be produced by a successful link or host-side synthetic exit.

## Supplemental SMP and notification evidence

The kick Guest emits one marker, runs a long loop, then emits a second marker. The test requires:

```text
first Guest marker line < first target-CPU IPI ISR line < second Guest marker line
```

It also verifies the ISR ran on CPU 0 and that the Core resumed Guest execution and completed shutdown. This demonstrates adapter notification/progress while the owner is in the Guest execution interval under TCG. It does not establish how a particular physical AMD CPU/KVM version delivers that interrupt across a native `VMRUN` window.

The oversubscription test uses four independent micro-Guest one-vCPU VMs, alternating affinity over two Zephyr CPUs. It covers host scheduler progress and adapter task lifetime, not Linux or x86 AP startup/SIPI. These results are retained as supplemental regressions and are not used to claim that Linux SMP passed.

## Contract and port cost answers

1. **How much did the Core change?** Eight files, `+114/-23`, net +91 physical diff lines in five host-neutral patches.
2. **How large is the Zephyr adapter?** 1,449 physical lines; build/Guest/test integration is another 1,962 lines. The generated `loc-report.txt` is authoritative.
3. **How much did Zephyr change?** Zero kernel files and zero kernel LOC; this is an external module/application.
4. **Which operations map directly?** Console, CPU count/current CPU, monotonic clock, yield and TSC discovery.
5. **Which need complex glue?** Physical ownership/contiguity, wait/wake race closure, opaque task lifetime, custom Core per-CPU base, Rust closure callbacks, and dedicated x86 IPI routing.
6. **Which semantics are truly OS-dependent?** Scheduler/thread handles, block/wake primitive, physical page authority/mapping, timer programming, IRQ registration/delivery and CPU-affinity/topology mechanisms.
7. **Did a Guest execute?** Yes: Linux reached PID 1 and ran `uname` under SVM modeled by QEMU TCG; native hardware is blocked.
8. **Did SMP work?** Zephyr's two host CPUs initialize/teardown SVM. Supplemental micro-Guest oversubscription passes; Linux SMP/AP-SIPI is not claimed.
9. **Does the lifetime protocol hold?** The actual windows present in this Core revision pass targeted tests; no claim is made for a named state machine absent from the source.
10. **What evidence does this provide for the RQ?** A third host maps the same explicit authority set and reaches Guest execution without a Zephyr-specific Core API. The remaining Core changes correct host-neutral lifetime/backend bugs rather than expanding host authority.

## Artifact index

| Artifact | Meaning |
|---|---|
| `environment.txt`, `versions.txt`, `*-commit.txt` | Host/tool/source provenance. |
| `contract-inventory.tsv` | Parser-generated exact operation list. |
| `baseline.log` | Zephyr-only SMP/MMU/primitives baseline. |
| `contract-tests.log` | Adapter functional contract tests. |
| `lifetime-tests.log` | Forced windows and negative control. |
| `linux-guest-tcg.log` | Linux kernel, PID 1, SystemDown and clean-teardown acceptance log. |
| `svm-probe-tcg.log` | Emulated SVM/NPT capability probe. |
| `svm-single-vcpu-tcg.log` | Complete Guest entry/exit/lifecycle log. |
| `svm-kick-tcg.log` | Directed IPI Guest-window evidence. |
| `smp.log`, `smp-stress-*.log` | Summary and raw repeated oversubscription logs. |
| `hardware-capability.log`, `svm-native.log`, `vmx-probe.log`, `vmx-single-vcpu.log` | Explicit native-hardware blockers. |
| `loc-report.txt` | Reproducible port-cost count. |

## Reproduction

```sh
./scripts/zephyr/setup.sh
./scripts/zephyr/build-qemu-tcg.sh
./scripts/zephyr/test-all.sh

# Native probes are expected to return 2 on the recorded host:
./scripts/zephyr/run-svm.sh
./scripts/zephyr/run-vmx.sh
```

The default `test-all.sh` uses Linux—not the micro-Guest—as its VM execution acceptance test. Individual supplemental micro-Guest stages remain available as `run-tcg-svm.sh`, `test-kick.sh`, and `test-smp.sh`.

## Remaining work before a native-hardware paper claim

- run the same branch on an AMD host with `/dev/kvm`, `svm`, nested SVM if needed, and capture native SVM enable/entry/exit/disable;
- optionally run an Intel VMX build/adapter configuration on a VMX-capable host; the current branch intentionally selected the already existing SVM backend;
- add a same-VM 2/4-vCPU Linux Guest that performs AP startup and per-vCPU progress reporting;
- validate a physical interrupt causing a native Guest exit and directed cross-CPU kick;
- exercise a physical host IRQ through one of the registered IOAPIC-forwarding vectors;
- exercise physical-device passthrough if the evaluation claim expands beyond emulated COM1/IOAPIC/PIT;
- upstream the five host-neutral Core fixes and retire the local patches when pinned Core contains them.

Firecracker remains outside Phase 1: Zephyr does not provide Linux userspace or `/dev/kvm` semantics, and adding those to the substrate contract would confound the host-portability experiment.
