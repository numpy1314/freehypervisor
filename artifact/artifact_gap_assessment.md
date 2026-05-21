# HHAL Artifact Gap Assessment

## Purpose

This document replaces vague statements like “complete” with a precise assessment of:

- what is already present
- what is still missing
- what is a paper risk
- what is an engineering risk
- what should be done next

## Current Status Summary

The current `artifact/` directory is best described as:

> a **substantially built paper artifact draft** with a compilable Linux/KVM backend skeleton, but **not yet a fully validated or portability-proven HHAL implementation**

That wording is intentionally narrow.

## What Is Already Solid

### 1. Outer-layer API definition exists

Present artifacts:

- `artifact/hhal.h`
- `artifact/hhal_design.md`

What this means:

- the VMM-facing HHAL boundary has been explicitly defined
- the service decomposition is no longer hand-wavy
- the Linux/KVM user-visible control plane has been abstracted into named HHAL calls

Assessment:

- strong paper progress

### 2. Linux/KVM mapping exists

Present artifact:

- `artifact/hhal_linux_kvm_mapping.md`

What this means:

- the abstract API has a concrete KVM realization
- reviewers can audit the mapping call-by-call

Assessment:

- strong paper progress
- good implementation guide value

### 3. Minimal backend code exists and compiles

Present artifacts:

- `artifact/hhal_linux.c`
- `artifact/hhal_linux_x86_helpers.c`
- `artifact/hhal_linux_x86_helpers.h`

What this means:

- the design has crossed from pure documentation into executable code
- core object lifecycle and key control paths are implemented

Assessment:

- strong engineering progress
- still backend-skeleton level, not production level

### 4. Validation entry points exist

Present artifacts:

- `artifact/hhal_linux_smoke_test.c`
- `artifact/hhal_linux_minimal_guest.c`
- `artifact/run_on_kvm_host.md`
- `artifact/build_kvm_host_artifacts.sh`

What this means:

- there is now a defined path to validate the artifact on a real KVM host
- reproduction burden for reviewers is much lower than before

Assessment:

- very good artifact hygiene
- still waiting on real host execution evidence

## What Is Not Yet Complete

### 1. Real execution results now exist, but coverage is still narrow

Current situation:

- real host-side validation has now been obtained on a machine with `/dev/kvm`
- both the smoke test and the minimal guest demo have passed
- the extended state test has also passed for `FPU`, `LAPIC`, `EVENTS`, and `DEBUG`
- validation coverage is still limited to the current minimal scenarios

Impact:

- the artifact is now empirically grounded
- but not yet broadly stress-tested across richer guest paths

Paper risk:

- reduced from high to medium

Engineering risk:

- reduced from high to medium

Priority:

- medium

### 2. Backend feature coverage is partial

Still missing or partial in `artifact/hhal_linux.c`:

- many state families still return `HHAL_ERR_UNSUPPORTED`
- IRQ routing currently covers the declared `IRQCHIP` and `MSI` route types, but not a broader cross-architecture routing envelope
- no richer MMIO/IO completion model beyond minimal exit translation

Impact:

- the backend demonstrates the API shape, not the full service envelope

Paper risk:

- medium

Engineering risk:

- high

Priority:

- medium-high

### 3. State transport is still Linux-colored

Current situation:

- `REGS/SREGS/CPUID/MSRS/MP` currently use KVM-native payload conventions in the Linux backend

Impact:

- practical for implementation
- weakens the strongest portability interpretation of HHAL

Paper risk:

- medium-high

Engineering risk:

- medium

Priority:

- medium

### 4. Minimal guest demo is too small to prove robust x86 bring-up

Current situation:

- the guest payload is only `hlt`
- there is no richer instruction path, no MMIO/PIO, no interrupt path, no paging setup

Impact:

- proves minimal guest entry/exit only
- does not yet prove robust guest initialization semantics

Paper risk:

- medium

Engineering risk:

- medium

Priority:

- medium

### 5. No inner-layer implementation exists

Current situation:

- inner-layer HHAL is still represented by analysis and design claims, not code

Impact:

- the paper can still argue for two layers conceptually
- but only the outer layer currently has concrete realization

Paper risk:

- medium

Engineering risk:

- medium-high

Priority:

- lower than host validation, but strategically important

### 6. No non-Linux backend exists

Current situation:

- only Linux/KVM is implemented

Impact:

- proves realizability on one host substrate
- does not yet prove abstraction adequacy across host OSes

Paper risk:

- medium-high

Engineering risk:

- medium

Priority:

- lower than Linux host validation

## What The Artifact Can Honestly Claim Today

The artifact can honestly claim:

1. a named HHAL outer-layer API has been derived from measured Linux/KVM dependencies
2. that API has a concrete Linux/KVM mapping
3. a compilable Linux backend skeleton exists
4. minimal x86-oriented validation programs exist
5. the smoke test, minimal guest demo, and extended state test have executed successfully on a real KVM-capable host

The artifact should **not** yet claim:

1. full backend completeness
2. strict payload portability independent of KVM-native layouts
3. cross-host generality proven by implementation
4. inner-layer realization complete

## Reviewer Risk Assessment

### Most likely reviewer criticism

“You showed one real KVM host result, but how far does it generalize beyond this narrow demo?”

Response status:

- partially answered

### Second most likely reviewer criticism

“Your supposedly portable state API still looks like KVM structs in disguise.”

Response status:

- partially answered
- currently framed as a backend convention, not a portable ABI commitment

### Third most likely reviewer criticism

“You argue for a two-layer HHAL, but only implemented the outer layer.”

Response status:

- conceptually answered
- not yet implementation-complete

## Recommended Next Steps

### Priority 1: Preserve and present the validation evidence cleanly

Deliverable:

- a polished results artifact showing smoke test and minimal guest demo running on a host with `/dev/kvm`

Why first:

- this is now the strongest proof point and should be made reviewer-friendly

### Priority 2: Add a validation results artifact

Suggested file:

- `artifact/validation_results_template.md`

Contents:

- host CPU
- kernel version
- KVM module state
- command lines
- observed outputs
- pass/fail summary

Why second:

- makes empirical validation easy to record and reuse in the paper

### Priority 3: Improve the x86 bring-up path

Suggested scope:

- apply supported CPUID consistently
- optionally initialize a minimal MSR subset if needed
- expand beyond bare `hlt` if host behavior demands it

Why third:

- strengthens the demo without trying to build a whole VMM

### Priority 4: Reduce KVM-native payload leakage

Suggested scope:

- add typed HHAL helper structs for CPUID/MSR entries
- keep KVM-native layout support only inside the Linux backend

Why fourth:

- improves the purity of the portability story

### Priority 5: Implement one more major missing backend feature

Best candidate:

- `hhal_vm_set_irq_routing()`

Why:

- it closes a prominent currently-unimplemented outer-layer API

## Bottom Line

Current bottom line:

- **validated for the current minimal host-side scenarios**
- **still not complete as a full backend**
- **stronger than a draft-only artifact because it now has real KVM execution evidence**

That is the accurate status.
