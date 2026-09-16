# FreeHypervisor Zephyr x86_64 host port

This external Zephyr module links the pinned `no_std` Hypervisor Core as a Rust static library and implements its source-derived host contract through a stable C ABI. The current executable backend is the Core's existing AMD SVM implementation; no VM-entry/exit code lives in this directory.

Quick start:

```sh
./scripts/zephyr/setup.sh
./scripts/zephyr/build-qemu-tcg.sh
./scripts/zephyr/test-all.sh
```

The default acceptance suite builds Linux 7.1.0-rc6 from the pinned Linux submodule, boots it through the unchanged Core's SVM/NPT path, requires a real userspace PID 1 PASS marker, and verifies clean SystemDown/vCPU/SVM teardown. The older micro-Guest scripts remain supplemental race and oversubscription regressions; they are not the VM-execution acceptance criterion.

Native hardware status is intentionally separate:

```sh
./scripts/zephyr/run-hardware.sh
./scripts/zephyr/run-vmx.sh
```

Those commands return status 2 and write `BLOCKED` evidence when `/dev/kvm` or the corresponding host CPU feature is unavailable. A QEMU TCG SVM PASS is not a native-hardware PASS.

See `docs/zephyr-port/architecture.md`, `contract-inventory.md`, and `final-report.md` for the boundary, exact operation inventory and evidence interpretation.
