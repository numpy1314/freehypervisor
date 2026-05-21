# HHAL State Blob Layouts

## Purpose

`artifact/hhal.h` uses a generic state transport:

- `hhal_vcpu_get_state()`
- `hhal_vcpu_set_state()`
- `struct hhal_state_blob`

This document defines the expected payload shape for the baseline state IDs.

It is intentionally a **layout specification**, not a promise that HHAL must expose Linux/KVM structs directly.

## Common Rules

All state blobs follow these rules.

1. `state.id` selects the semantic state group.
2. `state.data` points to a caller-owned buffer.
3. `state.size` is both:
   - input: available buffer size
   - output: actual bytes consumed or required
4. If the supplied buffer is too small, the backend should return `HHAL_ERR_INVALID` or `HHAL_ERR_NOMEM` and set `state.size` to the required minimum when practical.
5. `*_ARCH_BASE` and above are reserved for architecture-private extensions.

## Baseline State IDs

### `HHAL_VCPU_STATE_REGS`

Semantic content:

- general-purpose architectural register file
- program counter / instruction pointer
- stack pointer
- flags / status register

Portable shape:

- flat register block
- fixed-width 64-bit slots for scalar architectural registers

Recommended backend strategy:

- define an internal per-architecture struct
- marshal to/from KVM `KVM_GET_REGS` / `KVM_SET_REGS`

Current Linux backend note:

- `artifact/hhal_linux.c` currently accepts and returns `struct kvm_regs` for this state ID

### `HHAL_VCPU_STATE_SREGS`

Semantic content:

- control registers
- segment or privilege metadata
- descriptor-table roots where applicable
- paging mode control

Portable shape:

- structured control-state block
- architecture-specific subfields are allowed

Recommended backend strategy:

- use `KVM_GET_SREGS` / `KVM_SET_SREGS` or `SREGS2`
- normalize only the subset the VMM actually needs

Current Linux backend note:

- `artifact/hhal_linux.c` currently accepts and returns `struct kvm_sregs` for this state ID

### `HHAL_VCPU_STATE_CPUID`

Semantic content:

- CPUID leaves or equivalent architectural feature enumeration presented to the guest

Portable shape:

- variable-length array of entries
- each entry should include:
  - function / leaf
  - subleaf / index
  - returned value words
  - flags

Recommended backend strategy:

- translate to/from `KVM_GET_CPUID2` / `KVM_SET_CPUID2`

Current Linux backend note:

- `artifact/hhal_linux.c` currently accepts and returns `struct kvm_cpuid2` followed by `nent` trailing `struct kvm_cpuid_entry2` entries

### `HHAL_VCPU_STATE_MSRS`

Semantic content:

- model-specific register set or architecture-equivalent control registers

Portable shape:

- variable-length array of `(index, value)` pairs

Recommended backend strategy:

- translate to/from `KVM_GET_MSRS` / `KVM_SET_MSRS`
- on non-x86 architectures, this state ID may be unsupported

Current Linux backend note:

- `artifact/hhal_linux.c` currently accepts and returns `struct kvm_msrs` followed by `nmsrs` trailing `struct kvm_msr_entry` entries

### `HHAL_VCPU_STATE_FPU`

Semantic content:

- floating-point and SIMD execution state

Portable shape:

- opaque architecture-specific binary payload

Recommended backend strategy:

- forward as a byte block after capability check
- map to `KVM_GET_FPU` / `KVM_SET_FPU` on x86

Current Linux backend note:

- `artifact/hhal_linux.c` currently accepts and returns `struct kvm_fpu` for this state ID

### `HHAL_VCPU_STATE_LAPIC`

Semantic content:

- local interrupt controller state

Portable shape:

- opaque architecture-specific binary payload

Recommended backend strategy:

- x86 backend maps to `KVM_GET_LAPIC` / `KVM_SET_LAPIC`
- other architectures may reject with `HHAL_ERR_UNSUPPORTED`

Current Linux backend note:

- `artifact/hhal_linux.c` currently accepts and returns `struct kvm_lapic_state` for this state ID

### `HHAL_VCPU_STATE_MP`

Semantic content:

- multiprocessor startup state
- reset/init/runnable/halted state machine

Portable shape:

- small fixed struct containing:
  - logical MP state enum
  - optional flags

Recommended backend strategy:

- map to `KVM_GET_MP_STATE` / `KVM_SET_MP_STATE`

Current Linux backend note:

- `artifact/hhal_linux.c` currently accepts and returns `struct kvm_mp_state` for this state ID

### `HHAL_VCPU_STATE_EVENTS`

Semantic content:

- pending exceptions
- interrupt-window state
- NMI/SMI injection state when supported

Portable shape:

- structured event-state block
- fields are architecture-sensitive

Recommended backend strategy:

- map to `KVM_GET_VCPU_EVENTS` / `KVM_SET_VCPU_EVENTS`

Current Linux backend note:

- `artifact/hhal_linux.c` currently accepts and returns `struct kvm_vcpu_events` for this state ID

### `HHAL_VCPU_STATE_DEBUG`

Semantic content:

- hardware debug registers or equivalent trap-control state

Portable shape:

- opaque or semi-structured debug-state block

Recommended backend strategy:

- map to `KVM_GET_DEBUGREGS` / `KVM_SET_DEBUGREGS` where supported

Current Linux backend note:

- `artifact/hhal_linux.c` currently accepts and returns `struct kvm_debugregs` for this state ID

### `HHAL_VCPU_STATE_XSAVE`

Semantic content:

- extended CPU state save area

Portable shape:

- opaque byte buffer

Recommended backend strategy:

- map to `KVM_GET_XSAVE` / `KVM_SET_XSAVE`
- capability-gated

### `HHAL_VCPU_STATE_XCRS`

Semantic content:

- extended control register set or architecture-equivalent execution-context controls

Portable shape:

- small structured array of `(index, value)` entries

Recommended backend strategy:

- map to `KVM_GET_XCRS` / `KVM_SET_XCRS`
- capability-gated

### `HHAL_VCPU_STATE_SIGNAL_MASK`

Semantic content:

- host-side signal mask applied during guest run

Portable shape:

- packed bitmask as an array of 64-bit words

Recommended backend strategy:

- Linux backend marshals to `KVM_SET_SIGNAL_MASK`
- non-Linux backends may reject with `HHAL_ERR_UNSUPPORTED`

## Recommended Portable Payload Families

To keep future revisions coherent, blob payloads should fall into one of four families.

### 1. Fixed struct

Use for:

- MP state
- small control blocks

### 2. Variable-length entry array

Use for:

- CPUID-like data
- MSR-like data
- XCR-like data

### 3. Opaque byte block

Use for:

- FPU
- XSAVE
- LAPIC-like backend snapshots

### 4. Arch-private extension block

Use for:

- state IDs `>= HHAL_VCPU_STATE_ARCH_BASE`

## Suggested Future Typed Public Structs

If the API evolves beyond pure artifact form, the most valuable typed public structs to add first are:

1. `hhal_cpuid_entry`
2. `hhal_msr_entry`
3. `hhal_mp_state`
4. `hhal_xcr_entry`

These give the best balance between portability and type safety without forcing all state families into frozen public C layouts.

## What This Document Deliberately Avoids

It does not:

- freeze Linux/KVM struct layouts as HHAL ABI
- claim that every architecture must support every state ID
- force a single cross-architecture register schema for all CPU families

That restraint is intentional. The purpose of HHAL is to define a portable control boundary, not to pretend that all CPU architectures expose identical state.
