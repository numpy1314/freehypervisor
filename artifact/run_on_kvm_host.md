# Running The HHAL Artifacts On A KVM Host

## Purpose

This note explains how to build and run the current HHAL Linux/KVM artifacts on a host that has:

- `/dev/kvm`
- x86_64 KVM support
- a C compiler
- the Linux KVM userspace headers

The goal is reproducibility for reviewers and for future local validation.

## What You Can Run

Six runnable programs are currently provided.

### 1. Smoke test

Source:

- `artifact/hhal_linux_smoke_test.c`

What it validates:

- KVM API version query
- VM creation
- VCPU creation
- minimal state round-trip:
  - `REGS`
  - `SREGS`
  - `MP`
- clean teardown

### 2. Minimal guest demo

Source:

- `artifact/hhal_linux_minimal_guest.c`

What it validates:

- guest RAM registration
- optional supported CPUID fetch through the Linux/x86 helper
- minimal x86 state initialization
- one `KVM_RUN`
- expected `HHAL_EXIT_HLT`

This is the stronger end-to-end artifact.

### 3. Extended state test

Source:

- `artifact/hhal_linux_extended_state_test.c`

What it validates:

- host-side round-trip for additional x86-oriented VCPU state families:
  - `FPU`
  - `LAPIC`
  - `EVENTS`
  - `DEBUG`
  - `XSAVE`
  - `XCRS`

This is narrower than the guest demo, but broader than the original smoke test in backend control-plane coverage.

### 4. IRQ routing test

Source:

- `artifact/hhal_linux_irq_routing_test.c`

What it validates:

- x86/KVM irqchip setup ordering:
  - `KVM_SET_TSS_ADDR`
  - `KVM_CREATE_IRQCHIP`
- real host-side `hhal_vm_set_irq_routing()` success for:
  - one `IRQCHIP` route
  - one `MSI` route
- routed `GSI 0` accepts `hhal_vm_irq_line()` assert/deassert

### 5. Signal mask test

Source:

- `artifact/hhal_linux_signal_mask_test.c`

What it validates:

- `HHAL_VCPU_STATE_SIGNAL_MASK` can be written through `hhal_vcpu_set_state()`
- direct `hhal_vcpu_signal_mask()` helper path also succeeds
- Linux/KVM accepts the current one-word signal-mask payload used by this artifact

### 6. Guest IRQ delivery demo

Source:

- `artifact/hhal_linux_irq_delivery_guest.c`

What it validates:

- routed `GSI 0 -> PIC master pin 0` configuration
- guest-side real-mode IVT handling for vector `0x08`
- end-to-end interrupt delivery that changes guest-visible RAM
- expected guest halt after the interrupt handler runs

## Host Prerequisites

Check these first:

```bash
test -e /dev/kvm && echo "/dev/kvm present"
uname -m
lsmod | grep '^kvm'
```

If `/dev/kvm` exists but you do not have permission to open it, either:

- add your user to the `kvm` group and re-login
- or run the test binaries with `sudo`

## Build Commands

Run from the repository root.

### Build smoke test

```bash
cc -std=c11 -Wall -Wextra -Werror \
  artifact/hhal_linux.c \
  artifact/hhal_linux_smoke_test.c \
  artifact/hhal_linux_x86_helpers.c \
  -Iartifact \
  -o /tmp/hhal_linux_smoke_test
```

### Build minimal guest demo

```bash
cc -std=c11 -Wall -Wextra -Werror \
  artifact/hhal_linux.c \
  artifact/hhal_linux_minimal_guest.c \
  artifact/hhal_linux_x86_helpers.c \
  -Iartifact \
  -o /tmp/hhal_linux_minimal_guest
```

### Build extended state test

```bash
cc -std=c11 -Wall -Wextra -Werror \
  artifact/hhal_linux.c \
  artifact/hhal_linux_extended_state_test.c \
  artifact/hhal_linux_x86_helpers.c \
  -Iartifact \
  -o /tmp/hhal_linux_extended_state_test
```

### Build IRQ routing test

```bash
cc -std=c11 -Wall -Wextra -Werror \
  artifact/hhal_linux.c \
  artifact/hhal_linux_irq_routing_test.c \
  artifact/hhal_linux_x86_helpers.c \
  -Iartifact \
  -o /tmp/hhal_linux_irq_routing_test
```

### Build signal mask test

```bash
cc -std=c11 -Wall -Wextra -Werror \
  artifact/hhal_linux.c \
  artifact/hhal_linux_signal_mask_test.c \
  artifact/hhal_linux_x86_helpers.c \
  -Iartifact \
  -o /tmp/hhal_linux_signal_mask_test
```

### Build guest IRQ delivery demo

```bash
cc -std=c11 -Wall -Wextra -Werror \
  artifact/hhal_linux.c \
  artifact/hhal_linux_irq_delivery_guest.c \
  artifact/hhal_linux_x86_helpers.c \
  -Iartifact \
  -o /tmp/hhal_linux_irq_delivery_guest
```

## Run Commands

### Run smoke test

```bash
/tmp/hhal_linux_smoke_test
```

Expected success shape:

- KVM API version query succeeds
- VM create succeeds
- VCPU create succeeds
- `REGS` / `SREGS` / `MP` round-trips succeed
- process exits with code 0

### Run minimal guest demo

```bash
/tmp/hhal_linux_minimal_guest
```

Expected success shape:

- optional CPUID query succeeds, or prints a warning if skipped
- guest memory is mapped
- VCPU state is initialized
- one `KVM_RUN` returns `HHAL_EXIT_HLT`
- process exits with code 0

The key success line is:

```text
Minimal HHAL guest reached HLT successfully
```

### Run extended state test

```bash
/tmp/hhal_linux_extended_state_test
```

Expected success shape:

- `FPU` round-trip succeeds
- `LAPIC` round-trip succeeds
- `EVENTS` round-trip succeeds
- `DEBUG` round-trip succeeds
- `XSAVE` round-trip succeeds
- `XCRS` round-trip succeeds
- process exits with code 0

### Run IRQ routing test

```bash
/tmp/hhal_linux_irq_routing_test
```

Expected success shape:

- irqchip creation succeeds
- `IRQCHIP` route install succeeds
- `MSI` route install succeeds
- routed `GSI 0` assert/deassert succeeds
- process exits with code 0

### Run signal mask test

```bash
/tmp/hhal_linux_signal_mask_test
```

Expected success shape:

- `SIGNAL_MASK` state write succeeds
- direct signal mask write succeeds
- process exits with code 0

### Run guest IRQ delivery demo

```bash
/tmp/hhal_linux_irq_delivery_guest
```

Expected success shape:

- irqchip creation succeeds
- route install succeeds
- guest enters successfully
- guest interrupt handler writes the expected flag byte
- process exits with code 0

## Failure Interpretation

### `/dev/kvm` missing

Likely causes:

- KVM module not loaded
- running inside a container/VM without nested virtualization
- host platform does not expose hardware virtualization

### `HHAL_ERR_DENIED`

Likely cause:

- permission denied on `/dev/kvm`

### `HHAL_ERR_UNSUPPORTED`

Likely causes:

- kernel headers and runtime capability mismatch
- optional ioctl path not supported on that kernel

### Unexpected exit reason in minimal guest demo

Likely causes:

- host KVM behavior differs from the expected minimal x86 path
- initial register/segment setup is insufficient on that host/kernel combination

In that case, the next debugging step is to print:

- `run.exit_reason`
- the initial `regs` and `sregs`

## Recommended Validation Order

Run in this order:

1. build smoke test
2. run smoke test
3. build extended state test
4. run extended state test
5. build IRQ routing test
6. run IRQ routing test
7. build signal mask test
8. run signal mask test
9. build guest IRQ delivery demo
10. run guest IRQ delivery demo
11. build minimal guest demo
12. run minimal guest demo

If the smoke test fails, fix that first. The later tests depend on the same backend path plus additional state/control coverage.

## Current Scope Limit

Passing these programs does **not** mean the HHAL backend is production-ready.

It only demonstrates:

- object lifecycle works
- core state API works for the implemented subset
- additional x86-oriented state families can be round-tripped on the host
- basic IRQ routing and irq line control work on the host
- one routed interrupt can be observed by guest code
- one minimal guest execution path works

That is exactly the intended validation scope for the current paper artifact stage.
