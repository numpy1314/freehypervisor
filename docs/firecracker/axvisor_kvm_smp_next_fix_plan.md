# AxVisor KVM Firecracker SMP Current State and Next Fix Plan

Date: 2026-07-06

This note consolidates the current Firecracker SMP state with the concurrency
contract in `docs/firecracker/axvisor_kvm_concurrency_model.md`, and it is the
single detailed scheduling/fix plan for the next implementation step.

## Target Contract

The intended model is still:

- Native AxVisor may create one host task per vCPU and directly drive a Linux
  guest.
- KVM backend mode must let Firecracker create one host thread per vCPU and
  drive that vCPU through `KVM_RUN`.
- AxVisor owns VM/vCPU state and guest entry/exit semantics, but it must not
  become a global vCPU scheduler.
- Cross-vCPU events such as SIPI/CPU_UP update the target vCPU state and wake
  the target wait queue. The source vCPU must not run the target vCPU.
- Internal exits may be handled inside the current vCPU thread, but userspace
  device-model exits must return through the KVM ABI.

The current objective is not to add a scheduler inside AxVisor. It is to make
each Firecracker vCPU thread able to make forward progress while preserving the
existing native AxVisor direct-boot path.

## Resolved Design Decisions

The 2026-07-09 design review fixed the first implementation slice:

1. The old `AXKVM_BACKEND_EXIT_RESCHEDULE -> -EINTR` path is removed from the
   backend ABI and is not a scheduling mechanism.
2. `PreemptionTimer` and idle HLT are internal virtual time and interrupt
   progress events: expire due timers, advance PIT/PIC/LAPIC/IOAPIC state,
   inject pending IRQs, optionally yield, and continue the same `KVM_RUN`.
3. CPU_UP/SIPI is a target AP state transition. The BSP thread must only update
   target AP state and wake it; it must never enter or run the AP vCPU.
4. SIPI-installed AP entry state has priority over stale userspace
   `KVM_SET_REGS`/`KVM_SET_SREGS` state cached before the SIPI.
5. AP vCPUs in `KVM_MP_STATE_UNINITIALIZED` / Wait-for-SIPI block on their own
   wait queue and return only for SIPI/CPU_UP wakeup, `immediate_exit`, or a
   pending signal.
6. Host scheduling checkpoints are weak hints only: `cond_resched()` in C or
   `yield_now()` in Rust. `schedule_timeout(1)` is not part of the normal fast
   path.
7. The long `run_vcpu` path must not hold the VM global lock or any global run
   lock. VM locks protect lifecycle/configuration only.
8. Each vCPU's `struct kvm_run` page and pending MMIO/PIO readback are owned
   only by that vCPU's Firecracker thread.
9. First-stage VM configuration is frozen after backend boot: dynamic memslot,
   irqchip, PIT, irq routing, ioeventfd, and irqfd changes are out of scope.
10. VM exits are classified as internal-continue, userspace KVM exits, or
    interrupt returns. Firecracker sees only exits it must handle.
11. Validation order is Firecracker 1-vCPU initramfs, Firecracker 1-vCPU
    rootfs/blk, L1 native regression, then Firecracker 2-vCPU SMP.
12. If the minimal SIPI handling still fails SMP after 1-vCPU is restored,
    upgrade to a KVM-like `pending_init` / `pending_sipi` model where the AP
    consumes SIPI in its own `KVM_RUN` path.

## Final Scheduling Model

There are three schedulers or drivers in the system. They must not be confused.

| Layer | Owner | Responsibility |
|---|---|---|
| Host OS scheduler | Linux | Schedules host kernel threads and Firecracker userspace threads. |
| Firecracker | Userspace VMM | Creates one thread per vCPU and calls `KVM_RUN` on each vCPU fd. |
| AxVisor | VM/vCPU backend | Owns guest state, VM entry/exit, APIC/timer/IRQ semantics, and KVM exit translation. |

AxVisor does not choose which vCPU runs next in KVM-backend mode. The currently
calling Firecracker vCPU thread owns the current `KVM_RUN`.

### Two Execution Modes

Native AxVisor mode directly boots a Linux guest without Firecracker:

```text
AxVisor VM start
  -> create one host task per vCPU
  -> each host task runs drive_native_vcpu(vcpu_id)
  -> host OS schedules those tasks
```

Native mode may contain an AxVisor-owned vCPU task loop because there is no
userspace VMM calling `KVM_RUN`.

KVM backend mode serves unmodified Firecracker:

```text
Firecracker vCPU thread i
  -> ioctl(vcpu_fd_i, KVM_RUN)
  -> axvisor_kvm.ko
  -> AxVisor runs vCPU i only
  -> returns a KVM ABI exit or continues internal progress
```

KVM backend mode must not create a second AxVisor scheduler for Firecracker's
vCPUs. Firecracker already created the vCPU threads. Linux schedules those
threads.

### Primitive Boundary

The backend should expose this conceptual primitive:

```text
run_current_vcpu_once(vm, vcpu_id) -> VmExit
```

Properties:

- It enters only `vcpu_id`.
- It returns after one hardware/backend VM exit.
- It never selects another vCPU.
- It never runs AP work on behalf of BSP.
- It may update shared VM/device state caused by the current exit.

Higher-level loops are mode-specific:

```text
native_vcpu_task(vcpu_id):
  while vm is running:
    exit = run_current_vcpu_once(vcpu_id)
    handle_native_exit(exit)

KVM_RUN(vcpu_fd):
  while allowed:
    exit = run_current_vcpu_once(vcpu_id)
    action = classify_exit(exit)
    if action == internal_continue:
      continue or host_yield_then_continue
    if action == userspace_exit:
      write struct kvm_run
      return 0
    if action == interrupt_or_signal:
      return -EINTR
```

### KVM_RUN State Machine

```text
            +------------------+
            | KVM_RUN entered  |
            +------------------+
                      |
                      v
        +---------------------------+
        | complete pending readback |
        | if previous MMIO/PIO read |
        +---------------------------+
                      |
                      v
        +---------------------------+
        | wait if vCPU not runnable |
        | e.g. AP WaitForSIPI       |
        +---------------------------+
                      |
                      v
        +---------------------------+
        | sync dirty vCPU state     |
        | into AxVisor backend      |
        +---------------------------+
                      |
                      v
        +---------------------------+
        | run current vCPU only     |
        +---------------------------+
                      |
                      v
        +---------------------------+
        | classify VM exit          |
        +---------------------------+
          |            |           |
          |            |           |
          v            v           v
   internal       userspace     signal /
   continue       KVM exit      immediate_exit
      |              |              |
      v              v              v
  same KVM_RUN    return 0       return -EINTR
```

This model allows internal looping, but only inside the current vCPU thread.
It does not allow a fixed loop budget to act as a scheduler policy.

### VM Exit Classification

Internal progress events normally stay inside the current `KVM_RUN` call:

- `PreemptionTimer`
- `ExternalInterrupt`
- `InterruptEnd` / EOI
- `Nothing`
- in-kernel PIT/PIC/LAPIC/IOAPIC maintenance
- internal serial/PIT/IRQ injection
- CPU_UP/SIPI side effects after the target vCPU has been marked runnable

Handling rule:

```text
handle internal event
if need_resched() or fairness checkpoint:
  cond_resched()
continue current KVM_RUN unless immediate_exit or signal is pending
```

Userspace KVM exits must return to Firecracker through `struct kvm_run`:

- MMIO read/write belonging to Firecracker's device model
- PIO read/write belonging to Firecracker's device model
- shutdown/system event
- fail-entry/internal error

Idle HLT is not a normal userspace exit while the guest is waiting for timer or
interrupt delivery. The backend treats it as an internal wait checkpoint and
returns to userspace only for `immediate_exit`, signal, shutdown, fail-entry, or
device-model exits. Unlike the fast path, this checkpoint may use a short
interruptible host sleep to avoid busy-spinning while the guest is halted.

Handling rule:

```text
write kvm_run exit fields
save pending read context if MMIO/PIO read
return 0
```

The next `KVM_RUN` completes pending readback before entering the guest again.

`-EINTR` is only for KVM ABI interruption semantics:

- `run->immediate_exit` is set.
- the current Firecracker thread has a pending unmasked signal.
- the AP wait path is interrupted before the AP is runnable.

`-EINTR` is not a normal scheduling tick and not a replacement for internal
guest progress.

### PreemptionTimer Rule

The final rule for `PreemptionTimer` is:

```text
PreemptionTimer:
  expire due KVM timers
  inject due PIT/APIC timer interrupts
  progress pending virtual IRQs
  perform a host scheduling checkpoint if needed
  continue current KVM_RUN
```

It must not normally produce:

```text
synthetic reschedule backend exit -> -EINTR -> Firecracker retries KVM_RUN
```

The latest failing 1-vCPU evidence shows that this pattern can become an empty
loop with no guest-visible event and no guest progress.

If a hard escape hatch is needed for debugging, it must be explicit and
diagnostic-only, for example:

```text
if debug_internal_exit_limit_reached:
  return KVM_EXIT_INTERNAL_ERROR with diagnostics
```

It should not be the normal scheduling mechanism.

### CPU_UP / SIPI Rule

CPU_UP is a cross-vCPU state transition, not a cross-vCPU run operation.

When BSP receives SIPI/CPU_UP for AP:

```text
BSP KVM_RUN thread:
  decode CPU_UP target lapic_id and entry
  setup target AP vCPU SIPI entry state
  set target mp_state = RUNNABLE
  wake target mp_state wait queue
  continue BSP KVM_RUN
```

The source BSP thread must not run the AP. The AP runs only when Firecracker's
AP vCPU thread returns from its WaitForSIPI wait and calls into the backend.

AP vCPU path:

```text
AP KVM_RUN thread:
  if mp_state == UNINITIALIZED:
    block on mp_state_wq
  when mp_state == RUNNABLE:
    sync AP vCPU state only if it will not overwrite SIPI state
    run AP vCPU
```

Important invariant:

- userspace's initial AP register state must not be replayed after SIPI in a
  way that overwrites the real-mode trampoline state installed by CPU_UP.

### Locking Model

The VM lock protects lifecycle and shared configuration:

- backend VM creation/destruction
- first backend boot
- memslot mutations
- vCPU list mutations
- irqchip/PIT/routing/ioeventfd/irqfd configuration

The VM lock must not cover the long-running `run_current_vcpu_once` path.

The vCPU lock protects per-vCPU state:

- KVM register state copied from userspace
- dirty-state flags
- `mp_state`
- pending MMIO/PIO read completion context
- local LAPIC state exposed through KVM ioctls

The vCPU lock must not serialize different vCPUs' `KVM_RUN` calls.

The current Rust bridge uses global VM/vCPU slot arrays. The intended ownership
is:

- VM slot is installed once and read mostly during run.
- vCPU slot is owned by its current `KVM_RUN` thread.
- cross-vCPU fields must be updated through narrow state transitions such as
  CPU_UP wakeup, not by running the target vCPU.

### Host Scheduling Checkpoints

Host scheduling checkpoints are allowed but must be semantically weak:

- `cond_resched()` in C is allowed after internal work.
- `yield_now()` in Rust is allowed as a fairness hint.
- `schedule_timeout(1)` is too strong for the normal fast path and should be
  reserved for explicit blocking waits, not generic guest progress.

Allowed use:

```text
internal event handled
if need_resched/fairness condition:
  cond_resched()
continue same KVM_RUN
```

Disallowed use:

```text
internal event handled
return -EINTR only to force Firecracker to schedule another vCPU
```

Firecracker/Linux scheduling should happen naturally because each vCPU already
has its own host thread.

## Current Evidence

### Previously proven baseline

The 2026-07-03 progress report recorded these passing baselines:

- L1 native x86 Linux-hosted AxVisor boots x86 Linux guests.
- L1 native SMP passed 1/2/4/8 vCPU rootfs guests.
- L2 KVM ABI init smoke and negative ABI tests passed.
- L2 unmodified Firecracker 1-vCPU initramfs/rootfs paths passed.
- L2 Firecracker rootfs virtio-blk readback passed.

The historical unresolved item was only `FC-SMP-2`.

### Latest automatic run

The latest automatic tests changed the current status:

- `output/x86-axvisor-test-matrix-auto-20260706-195648/summary.txt`
  reports `X86-L1-ROOTFS` pass and `X86-L1-INITRAMFS` fail.
- `X86-L1-INITRAMFS` reached `Run /init as init process` and later
  `reboot: Power down`, but the harness logged
  `AXVISOR_X86_NATIVE_RUN_FAIL=timeout-inside-host`.
- `/tmp/axvisor-kvm-firecracker.auto-fc-1vcpu-20260706-200230/qemu.log`
  shows Firecracker 1-vCPU now times out. vCPU0 repeatedly enters backend and
  returns `Ok(PreemptionTimer)` without reaching
  `AXVISOR_FIRECRACKER_GUEST_PASS=1`.
- `/tmp/axvisor-kvm-firecracker.fc-smp-2-cpuup-sleep-yield-20260706-181957/qemu.log`
  shows the 2-vCPU run gets further than the original failure:
  `CPU_UP` marks vCPU1 runnable and vCPU1 enters the backend. It then loops on
  `PreemptionTimer`.

This means the current worktree has regressed the L2 1-vCPU Firecracker
baseline. FC-SMP-2 debugging must not continue until the 1-vCPU baseline is
restored.

### 2026-07-09 first-stage fix result

The first-stage fix restored the Firecracker 1-vCPU initramfs baseline:

```text
run dir: /tmp/axvisor-kvm-firecracker.fc-1vcpu-no8250-initfix2-20260709-021302
result:  AXVISOR_FIRECRACKER_GUEST_PASS=1
mode:    FIRECRACKER_GUEST_BOOT_MODE=initramfs
vcpus:   FIRECRACKER_VCPU_COUNT=1
```

The same gate was re-run after a fresh current-source build:

```text
build dir: /tmp/axvisor-kvm-x86-first-stage-audit-build
run dir:   /tmp/axvisor-kvm-firecracker.fc-1vcpu-first-stage-audit-20260709-022659
module:    /tmp/axvisor-kvm-x86-first-stage-audit-build/drivers/virt/axvisor/axvisor_kvm.ko
kernel:    /tmp/axvisor-kvm-x86-first-stage-audit-build/arch/x86/boot/bzImage
result:    AXVISOR_FIRECRACKER_GUEST_PASS=1
mode:      FIRECRACKER_GUEST_BOOT_MODE=initramfs
vcpus:     FIRECRACKER_VCPU_COUNT=1
```

The guest evidence contains `Run /init as init process`,
`FC_PASS=1`, `AXVISOR_FIRECRACKER_GUEST_PASS=1`, and
`AXVISOR_FIRECRACKER_GUEST_STAGE=idle`. No `Attempted to kill init` panic was
observed in this run.

An extra Firecracker 1-vCPU rootfs/tiny check was also attempted at
`/tmp/axvisor-kvm-firecracker.fc-1vcpu-rootfs-tiny-regress-20260709-021347`.
That run mounted `/dev/vda` and reached `/init`, but did not create
`/axvisor-firecracker-result.txt`; it remains a separate rootfs/tiny init or
virtio-blk writeback issue and is not part of the restored initramfs acceptance
gate.

## Historical Code Divergence and Current Fix Status

The regression came from three mechanisms that existed in the earlier
implementation:

1. C-side `KVM_RUN` loops around backend `run_vcpu`.
2. Rust bridge treats `PreemptionTimer`, `ExternalInterrupt`, `Nothing`, EOI,
   and in-kernel IRQ/PIT events as internal exits.
3. A fixed `KVM_RUN_INTERNAL_EXIT_BUDGET` returned a synthetic reschedule exit;
   C converted that to `-EINTR`.

This conflicts with the concurrency model in one specific way: the model says
the backend should not use a fixed loop budget as a scheduling policy. The
failing 1-vCPU log showed a `PreemptionTimer -> RESCHEDULE -> -EINTR ->
KVM_RUN` cycle with no guest-visible progress.

The first-stage fix removes this from the normal path:

- Rust-side internal-exit progress no longer returns
  a synthetic reschedule exit as a budgeted scheduling mechanism.
- The synthetic reschedule backend exit is removed from the C/Rust ABI. Weak
  scheduling checkpoints remain `cond_resched()` / `yield_now()` hints inside
  the current `KVM_RUN`.
- `PreemptionTimer`, EOI, external interrupt, in-kernel MMIO/PIO, and idle HLT
  remain internal progress events in the current vCPU thread.

The CPU_UP path is partially correct now:

- The source vCPU does not run the target vCPU directly.
- The target AP vCPU is marked runnable and woken.
- vCPU1 reaches backend execution.

The CPU_UP path is not yet enough to claim FC-SMP-2 success because the AP can
still stall in Linux AP bring-up. That remaining SMP issue is separate from the
restored 1-vCPU initramfs baseline.

## Root-Cause Statement

The immediate 1-vCPU regression root cause was the internal-exit reschedule
policy, not the absence of AP wakeup.

The earlier implementation converted `PreemptionTimer` into a budgeted internal
loop that periodically returned `-EINTR` to Firecracker. That return was only a
host scheduling hint; it was not a KVM userspace exit carrying device-model
work. Repeated `KVM_RUN` calls re-entered the same guest state and hit
`PreemptionTimer` again, so both 1-vCPU and 2-vCPU runs could spin without
reaching the next meaningful guest event.

The FC-SMP-2 specific root cause remains the AP/BSP hotplug handshake, but it
can now be isolated against a restored 1-vCPU initramfs baseline.

## Next Fix Plan

### Step 1: Restore Firecracker 1-vCPU as the regression anchor

Change the KVM backend run policy so `PreemptionTimer` is handled as an
internal progress event without forcing a `RESCHEDULE -> -EINTR` cycle in the
normal 1-vCPU path.

Concrete direction:

- Remove or gate the fixed internal-exit budget from the normal
  `PreemptionTimer` path.
- Keep cheap host yielding inside the same `KVM_RUN` thread when needed, but do
  not use `-EINTR` as the default progress mechanism.
- Continue returning to userspace only for real KVM exits: MMIO/PIO device
  model exits, HLT, shutdown, fail-entry, internal error, `immediate_exit`, or
  pending signal.
- Verify with unmodified Firecracker 1-vCPU initramfs:
  `AXVISOR_FIRECRACKER_GUEST_PASS=1`.

Acceptance gate:

```text
/tmp/axvisor-kvm-firecracker.<run>/firecracker-result.txt contains
AXVISOR_FIRECRACKER_GUEST_PASS=1
```

### Step 2: Re-run L1 native smoke after Step 1

The latest matrix showed `X86-L1-INITRAMFS` failed at the harness level after
guest poweroff. Before SMP work continues, confirm whether this is:

- a real native-path regression, or
- a harness marker extraction/timeout issue.

Acceptance gate:

- `X86-L1-ROOTFS` passes.
- `X86-L1-INITRAMFS` either passes or has a documented harness-only cause with
  guest evidence showing the expected pass marker.

### Step 3: Re-test FC-SMP-2 with the restored 1-vCPU path

Only after Step 1 passes, run Firecracker 2-vCPU again.

Expected evidence from a correct partial run:

- vCPU1 waits in `KVM_MP_STATE_UNINITIALIZED`.
- BSP emits CPU_UP/SIPI.
- vCPU1 becomes runnable.
- vCPU1 enters backend.
- guest reports either `AXVISOR_FIRECRACKER_GUEST_CPU_ONLINE=0-1` or
  `AXVISOR_FIRECRACKER_GUEST_CPUINFO_COUNT=2`.

If vCPU1 still stalls after CPU_UP, the next debug target is no longer generic
scheduling. It is the AP/BSP Linux hotplug synchronization path:

- whether BSP continues far enough after CPU_UP to release the hotplug state;
- whether vCPU1 receives timer/IPI events needed while in
  `cpuhp_ap_sync_alive`;
- whether AP LAPIC timer/external interrupt injection is pending but blocked;
- whether vCPU1's KVM/APIC state is incorrectly replayed after SIPI.

### Step 4: Preserve the dual-mode boundary

Do not collapse native and KVM backend execution into one scheduler model.

Required invariant:

- Native mode may keep `drive_vcpu_task` style loops.
- KVM backend mode must keep `KVM_RUN(vcpu fd)` as the execution owner.
- Shared code should expose a `run_current_vcpu_until_exit` style primitive,
  not a global VM scheduler.

## Implementation Mapping

| Model concept | Current location | Target behavior |
|---|---|---|
| vCPU fd `KVM_RUN` owner | `linux-host-kernel/drivers/virt/axvisor/axvisor_kvm_main.c` | Runs only the vCPU associated with this fd. |
| pending MMIO/PIO readback | `axkvm_vcpu_run_backend_unmasked()` | Complete pending read before next guest entry. |
| AP WaitForSIPI blocking | `axkvm_vcpu_run_backend_unmasked()` | Block on `mp_state_wq`; return `-EINTR` only on signal/immediate exit. |
| CPU_UP target wake | `axkvm_handle_cpu_up()` | Set target `mp_state=RUNNABLE`, wake target, do not dirty-replay AP state. |
| internal VM exit loop | `axvisor_kvm_rs_run_vcpu()` | Handle current-vCPU internal exits and continue current `KVM_RUN`. |
| preemption timer progress | `axvisor_kvm_rs_run_vcpu()` | Expire timers, inject pending IRQs, fairness checkpoint, continue. |
| userspace KVM exits | `axkvm_translate_backend_exit()` | Populate `struct kvm_run` and return `0` to Firecracker. |
| host scheduling checkpoint | C `cond_resched()` / Rust `yield_now()` | Fairness hint only; not a userspace KVM exit. |

The following previous behavior has been removed from the normal run path:

```text
consume_internal_run_budget(...)
  -> synthetic reschedule backend exit
  -> C KVM_RUN returns -EINTR
```

Do not reintroduce a synthetic reschedule backend exit. If the backend needs a
hard debug escape, report `KVM_EXIT_INTERNAL_ERROR` with diagnostics instead of
using `-EINTR` as a progress mechanism.

## Implementation Pseudocode

### C-side `KVM_RUN`

```text
axkvm_vcpu_run_backend_unmasked(vcpu):
  if immediate_exit or signal_pending:
    return -EINTR

  if pending_mmio_or_pio_read:
    complete_pending_read_into_backend()

  if vcpu is AP and mp_state == UNINITIALIZED:
    wait_event_interruptible(mp_state_wq, runnable or immediate_exit)
    if interrupted or immediate_exit:
      return -EINTR

  if backend not booted:
    sync VM state
    sync all initial vCPU state
    boot backend VM

  sync this vCPU dirty state

  loop:
    if immediate_exit or signal_pending:
      return -EINTR

    exit = backend_run_vcpu(vcpu)

    if exit == CPU_UP:
      mark target AP runnable
      wake target AP wait queue
      cond_resched()
      continue

    if exit == internal_progress:
      cond_resched_if_needed()
      continue

    if exit == userspace_exit:
      translate_to_kvm_run(exit)
      return 0
```

### Rust bridge `run_vcpu`

```text
axvisor_kvm_rs_run_vcpu(backend_vcpu):
  set current vCPU context
  enter percpu
  apply pending vCPU state if needed

  loop:
    result = axvm.run_vcpu_raw(current_vcpu)

    match result:
      PreemptionTimer:
        expire_due_kvm_timers()
        progress_x86_virtual_irqs(current_vcpu)
        yield_now_as_hint()
        continue

      ExternalInterrupt | Nothing:
        progress_x86_virtual_irqs(current_vcpu)
        yield_now_as_hint()
        continue

      InterruptEnd(vector):
        complete_x86_external_eoi(current_vcpu, vector)
        progress_x86_virtual_irqs(current_vcpu)
        yield_now_as_hint()
        continue

      idle HLT:
        expire_due_kvm_timers()
        progress_x86_virtual_irqs(current_vcpu)
        return HLT checkpoint to C-side wrapper

      CPU_UP(target, entry):
        setup target AP SIPI entry
        return CPU_UP to C-side wrapper

      userspace MMIO/PIO/shutdown/fail:
        return translated backend exit to C-side wrapper

  leave percpu
```

## Proposed Validation Order

1. Build `axvisor_kvm.ko`.
2. Run Firecracker 1-vCPU initramfs.
3. Run Firecracker 1-vCPU rootfs/tiny or blk readback if initramfs passes.
4. Run L1 native rootfs and initramfs smoke.
5. Run Firecracker 2-vCPU initramfs.
6. If 2-vCPU still fails, add AP/BSP hotplug-specific instrumentation only.

## Do Not Do

- Do not add a global AxVisor vCPU scheduler to fix Firecracker SMP.
- Do not make the BSP run AP vCPU work directly.
- Do not treat `RESCHEDULE -> -EINTR` as a normal guest progress mechanism.
- Do not continue FC-SMP-2 experiments while Firecracker 1-vCPU is failing.
- Do not modify AxVisor public HostIf for this problem.
