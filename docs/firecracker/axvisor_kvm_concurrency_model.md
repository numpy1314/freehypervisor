# AxVisor KVM Backend Concurrency Model

Date: 2026-07-05

Update 2026-07-06: the detailed target scheduling state machine and next fix
plan are now merged into
`docs/firecracker/axvisor_kvm_smp_next_fix_plan.md`. This file keeps the
high-level concurrency contract; that merged fix plan is the authoritative
source for the next implementation step.

This document records the concurrency contract for the AxVisor `/dev/kvm`
backend. The goal is to support two execution modes without making AxVisor a
central vCPU scheduler:

1. Standalone AxVisor may create one host task per vCPU and directly boot a
   Linux guest.
2. KVM backend mode lets Firecracker create one host thread per vCPU and drive
   each vCPU through `KVM_RUN`.

In both modes, the host OS scheduler schedules the host task/thread. AxVisor
owns VM/vCPU state and guest entry/exit semantics, but it must not serialize all
vCPU execution through one global run lock.

## Review Decisions

The detailed fix plan records the complete 2026-07-09 decision set. The
high-level concurrency consequences are:

- Normal KVM backend progress must not use `RESCHEDULE -> -EINTR`.
- Internal exits such as `PreemptionTimer`, idle HLT, EOI, external interrupt,
  and in-kernel IRQ/timer work continue inside the current vCPU thread.
- CPU_UP/SIPI wakes the target AP but never lets the BSP run the AP.
- SIPI AP entry state wins over stale userspace register snapshots.
- AP Wait-for-SIPI blocks on the AP wait queue and wakes only for runnable
  state, `immediate_exit`, or signal.
- Long `run_vcpu` execution must not hold VM-global or global run locks.
- First-stage VM topology/configuration is frozen after backend boot.

## Execution Contract

The intended layering is:

```text
run_vcpu_once(vm, vcpu_id) -> exit
  Enter the current vCPU until one VM exit.
  Does not pick another vCPU.
  Does not act as a global scheduler.

standalone drive_vcpu_task(vm, vcpu_id)
  Used by native AxVisor.
  Runs in a host task created for that vCPU.
  Loops over run_vcpu_once for that same vCPU.

KVM_RUN(vcpu fd)
  Used by Firecracker.
  Runs in the Firecracker vCPU thread.
  Loops only for internal events of the current vCPU.
  Returns userspace exits as KVM ABI exits.
```

## Lock Ownership

VM-level lock protects VM lifecycle and shared configuration:

- `backend_booted`
- backend boot/init state synchronization
- memslots and vCPU list mutations
- irqchip, PIT, irq routing, ioeventfd, irqfd configuration

vCPU-level lock protects one vCPU state:

- KVM register state copied from userspace
- `mp_state` / WaitForSipi state
- pending MMIO/PIO read completion state
- local LAPIC state exposed through KVM ioctls

The vCPU run path must not hold a global lock that serializes different vCPUs.

## Rust Bridge Ownership Rules

The Rust bridge currently stores VM/vCPU slots in global arrays. After boot:

- `VMS[vm].vm` is installed once and then treated as shared read-mostly state
  in the run path.
- `VCPUS[i]` is owned by the corresponding KVM vCPU thread while executing
  `KVM_RUN`.
- per-vCPU pending MMIO/PIO completion is modified only by that vCPU owner
  thread.
- cross-vCPU events, such as SIPI/CPU_UP/IPI, must update only the target
  vCPU's state and wake the target wait queue. The source vCPU must not run the
  target vCPU directly.

## Exit Handling

Internal exits may be handled in the current vCPU thread:

- preemption timer
- external interrupt
- interrupt end / EOI
- in-kernel timer and interrupt progress

Userspace exits must return through the KVM ABI:

- MMIO/PIO read/write that belongs to Firecracker's device model
- shutdown/system event
- fail-entry/internal error

Idle HLT is handled inside the current `KVM_RUN` as a wait-for-interrupt
checkpoint. It is not exposed to Firecracker unless the backend classifies the
guest state as a real shutdown/fail condition. This idle-only path may block
briefly in the host so a halted guest does not busy-spin.

The backend does not use a fixed loop budget as a scheduling policy. If a vCPU
is not runnable it must block. `immediate_exit` or a pending signal returns from
the current `KVM_RUN`; scheduler pressure is only a weak in-kernel yield hint.

## First Implementation Slice

The first implementation slice intentionally targets only the L2 KVM backend:

1. keep VM boot under VM-level lock;
2. remove global run locking around `run_vcpu`;
3. preserve per-vCPU state ownership;
4. route CPU_UP/SIPI as target state update plus wake;
5. validate with two-vCPU concurrent `KVM_RUN`, Firecracker 1-vCPU regression,
   Firecracker 2-vCPU, and L1 native regression.
